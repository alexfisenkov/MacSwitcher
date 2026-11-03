using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using MacSwitcher.Core;

namespace MacSwitcher.Windows.Updates;

/// <summary>Explicit Windows update checks and downloads; no automatic install or background polling.</summary>
public sealed class WindowsUpdateService : IDisposable
{
    private const string Feed = "https://raw.githubusercontent.com/alexfisenkov/MacSwitcher/main/windows/updates/windows.json";
    private const int MaxFeedBytes = 20_000;
    private const long MaxInstallerBytes = 512L * 1024 * 1024;
    private readonly HttpClient client;
    private readonly int currentBuild;
    private readonly object gate = new object();
    private UpdateManifest? checkedManifest;
    private string? verifiedPath;
    private UpdateAsset? verifiedAsset;
    private bool disposed;

    public WindowsUpdateService(int currentBuild)
    {
        if (currentBuild < 0) throw new ArgumentOutOfRangeException(nameof(currentBuild));
        this.currentBuild = currentBuild;
        // .NET 4.6.2 on Windows 7/8.1 may otherwise negotiate an obsolete system default.
        ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
        var handler = new HttpClientHandler { AllowAutoRedirect = false, AutomaticDecompression = DecompressionMethods.None };
        client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(20) };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("MacSwitcher-Windows/0.1");
    }
    public async Task<UpdateManifest?> CheckAsync(CancellationToken token = default)
    {
        ThrowIfDisposed();
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
        budget.CancelAfter(TimeSpan.FromSeconds(30));
        var effective = budget.Token;
        lock (gate) { checkedManifest = null; verifiedPath = null; verifiedAsset = null; }
        using var response = await client.GetAsync(Feed, HttpCompletionOption.ResponseHeadersRead, effective).ConfigureAwait(false);
        if (response.StatusCode == HttpStatusCode.NotFound) return null;
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength.HasValue && response.Content.Headers.ContentLength.Value > MaxFeedBytes)
            throw new InvalidDataException("Windows update metadata exceeds limit");
        using var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false);
        using var memory = new MemoryStream();
        var buffer = new byte[4096];
        int read;
        while ((read = await input.ReadAsync(buffer, 0, buffer.Length, effective).ConfigureAwait(false)) > 0)
        {
            if (memory.Length + read > MaxFeedBytes) throw new InvalidDataException("Windows update metadata exceeds limit");
            memory.Write(buffer, 0, read);
        }
        var json = new System.Text.UTF8Encoding(false,true).GetString(memory.ToArray());
        var verified = SignedUpdateVerifier.Verify(json, currentBuild);
        lock (gate) { checkedManifest = verified; verifiedPath = null; verifiedAsset = null; }
        return verified;
    }
    public async Task<string> DownloadInstallerAsync(UpdateManifest manifest, CancellationToken token = default, Action<long,long>? progress = null)
    {
        ThrowIfDisposed();
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
        budget.CancelAfter(TimeSpan.FromMinutes(10));
        var effective = budget.Token;
        if (manifest == null) throw new ArgumentNullException(nameof(manifest));
        lock (gate)
        {
            if (!ReferenceEquals(checkedManifest, manifest)) throw new InvalidOperationException("Update was not checked in this session");
            verifiedPath = null; verifiedAsset = null;
        }
        var asset = manifest.Assets.Single(item => item.Name.EndsWith("-Setup.exe", StringComparison.Ordinal));
        if (asset.Size <= 0 || asset.Size > MaxInstallerBytes) throw new InvalidDataException("Invalid installer size");
        var cacheRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MacSwitcherWindows", "Updates");
        Directory.CreateDirectory(cacheRoot);
        var folder = Path.Combine(cacheRoot, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, asset.Name);
        try
        {
            // Signed URL is fixed to GitHub; a redirect is accepted only from GitHub's asset hosts.
            using var response = await GetAssetAsync(asset.DownloadUrl, effective).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength.HasValue && response.Content.Headers.ContentLength.Value != asset.Size)
                throw new InvalidDataException("Installer length mismatch");
            using var input = await response.Content.ReadAsStreamAsync().ConfigureAwait(false);
            using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true);
            using var sha = SHA256.Create();
            var buffer = new byte[65536]; long received = 0; int read;
            while ((read = await input.ReadAsync(buffer, 0, buffer.Length, effective).ConfigureAwait(false)) > 0)
            {
                received += read;
                if (received > asset.Size || received > MaxInstallerBytes) throw new InvalidDataException("Installer exceeds signed size");
                await output.WriteAsync(buffer, 0, read, effective).ConfigureAwait(false);
                sha.TransformBlock(buffer, 0, read, null, 0);
                progress?.Invoke(received, asset.Size);
            }
            sha.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
            await output.FlushAsync(effective).ConfigureAwait(false);
            if (received != asset.Size || !string.Equals(BitConverter.ToString(sha.Hash!).Replace("-", ""), asset.Sha256, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Installer hash or length mismatch");
            lock (gate) { verifiedPath = path; verifiedAsset = asset; }
            return path;
        }
        catch
        {
            try { Directory.Delete(folder, true); } catch { }
            throw;
        }
    }
    private async Task<HttpResponseMessage> GetAssetAsync(string signedUrl, CancellationToken token)
    {
        var current = new Uri(signedUrl, UriKind.Absolute);
        for (var redirect = 0; redirect < 4; redirect++)
        {
            if (current.Scheme != Uri.UriSchemeHttps || !AllowedAssetHost(current.Host)) throw new InvalidDataException("Untrusted update redirect");
            var response = await client.GetAsync(current, HttpCompletionOption.ResponseHeadersRead, token).ConfigureAwait(false);
            if ((int)response.StatusCode < 300 || (int)response.StatusCode >= 400) return response;
            var location = response.Headers.Location;
            response.Dispose();
            if (location == null) throw new InvalidDataException("Invalid update redirect");
            current = location.IsAbsoluteUri ? location : new Uri(current, location);
        }
        throw new InvalidDataException("Too many update redirects");
    }
    private static bool AllowedAssetHost(string host) =>
        host == "github.com" || host == "release-assets.githubusercontent.com" || host == "objects.githubusercontent.com";

    public void LaunchVerifiedInstaller(string path)
    {
        ThrowIfDisposed();
        UpdateAsset asset;
        lock (gate)
        {
            if (verifiedPath == null || verifiedAsset == null || !string.Equals(Path.GetFullPath(path), Path.GetFullPath(verifiedPath), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("Installer was not verified in this session");
            asset = verifiedAsset;
        }
        if (!File.Exists(path) || File.GetAttributes(path).HasFlag(FileAttributes.ReparsePoint)) throw new InvalidDataException("Installer file unavailable");
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (file.Length != asset.Size) throw new InvalidDataException("Installer length changed");
        using var sha = SHA256.Create();
        var hash = BitConverter.ToString(sha.ComputeHash(file)).Replace("-", "");
        if (!string.Equals(hash, asset.Sha256, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Installer hash changed");
        using var process = Process.Start(new ProcessStartInfo { FileName = path, UseShellExecute = true }) ?? throw new InvalidOperationException("Installer did not launch");
    }
    private void ThrowIfDisposed() { if (disposed) throw new ObjectDisposedException(nameof(WindowsUpdateService)); }
    public void Dispose() { if (disposed) return; disposed = true; client.Dispose(); }
}
