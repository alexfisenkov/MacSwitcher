using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;

[assembly: System.Runtime.CompilerServices.InternalsVisibleTo("MacSwitcher.Core.Tests")]
namespace MacSwitcher.Core;

public sealed class UpdateNotNewerException : IOException
{
    public UpdateNotNewerException() : base("No newer signed Windows update") { }
}

public sealed class UpdateAsset
{
    public string Name { get; }
    public string Sha256 { get; }
    public long Size { get; }
    public string DownloadUrl { get; }
    internal UpdateAsset(string name,string sha256,long size,string downloadUrl)
    { Name=name; Sha256=sha256; Size=size; DownloadUrl=downloadUrl; }
}
public sealed class UpdateManifest
{
    public string Version { get; }
    public int Build { get; }
    public string Tag { get; }
    public string SourceRevision { get; }
    public IReadOnlyList<UpdateAsset> Assets { get; }
    internal UpdateManifest(string version,int build,string tag,string sourceRevision,IReadOnlyList<UpdateAsset> assets)
    { Version=version; Build=build; Tag=tag; SourceRevision=sourceRevision; Assets=assets; }
}

/// <summary>Verifies the embedded Windows release trust anchor before exposing any update URL.</summary>
public static class SignedUpdateVerifier
{
    private const string Repository = "https://github.com/alexfisenkov/MacSwitcher/releases/download/";
    private const int MaxEnvelopeBytes = 20_000;
    private const int MaxPayloadBytes = 8_192;
    private const long MaxAssetBytes = 512L * 1024 * 1024;
    private static readonly UTF8Encoding StrictUtf8 = new UTF8Encoding(false,true);
    private static readonly Regex VersionPattern = new Regex(@"^0\.[0-9]+\.[0-9]+(?:-alpha\.[1-9][0-9]*)?$",RegexOptions.CultureInvariant);
    private static readonly Regex ShaPattern = new Regex("^[0-9a-f]{64}$",RegexOptions.CultureInvariant);
    private static readonly Regex RevisionPattern = new Regex("^[0-9a-f]{40}$",RegexOptions.CultureInvariant);
    public static UpdateManifest Verify(string envelopeJson,int currentBuild) => VerifyWithKey(envelopeJson,currentBuild,ReadEmbeddedKey());
    internal static UpdateManifest VerifyWithKey(string envelopeJson,int currentBuild,RSAParameters key)
    {
        if (currentBuild < 0 || envelopeJson == null || StrictUtf8.GetByteCount(envelopeJson)>MaxEnvelopeBytes) throw new InvalidDataException("Invalid update envelope size");
        Envelope envelope;
        try { envelope=Deserialize<Envelope>(StrictUtf8.GetBytes(envelopeJson)); }
        catch(Exception error) when(error is SerializationException || error is ArgumentException) { throw new InvalidDataException("Invalid update envelope",error); }
        if (envelope.Algorithm != "RSA-SHA256" || envelope.Payload == null || envelope.Signature == null ||
            envelopeJson.Trim() != "{\"algorithm\":\"RSA-SHA256\",\"payload\":\""+envelope.Payload+"\",\"signature\":\""+envelope.Signature+"\"}")
            throw new InvalidDataException("Noncanonical update envelope");
        byte[] payload, signature;
        try { payload=DecodeBase64(envelope.Payload); signature=DecodeBase64(envelope.Signature); }
        catch(FormatException error) { throw new InvalidDataException("Invalid update encoding",error); }
        if (payload.Length==0 || payload.Length>MaxPayloadBytes || signature.Length!=key.Modulus?.Length) throw new InvalidDataException("Invalid update payload or signature size");
        using(var rsa=RSA.Create())
        {
            rsa.ImportParameters(key);
            if (!rsa.VerifyData(payload,signature,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1)) throw new CryptographicException("Invalid update signature");
        }
        Payload candidate;
        try { candidate=Deserialize<Payload>(payload); }
        catch(Exception error) when(error is SerializationException || error is ArgumentException) { throw new InvalidDataException("Invalid update payload",error); }
        if (candidate.Schema!=1 || candidate.Version==null || !VersionPattern.IsMatch(candidate.Version) || candidate.Build<=0 ||
            candidate.Tag!="windows-v"+candidate.Version || candidate.SourceRevision==null || !RevisionPattern.IsMatch(candidate.SourceRevision) ||
            candidate.Assets==null || candidate.Assets.Length!=2) throw new InvalidDataException("Invalid update identity");
        var setup="MacSwitcher-Windows-"+candidate.Version+"-Setup.exe";
        var portable="MacSwitcher-Windows-"+candidate.Version+"-portable.zip";
        var actual=new List<UpdateAsset>();
        for(var i=0;i<2;i++)
        {
            var item=candidate.Assets[i]; var expectedName=i==0?setup:portable;
            var expectedUrl=Repository+candidate.Tag+"/"+expectedName;
            if (item==null || item.Name!=expectedName || item.Sha256==null || !ShaPattern.IsMatch(item.Sha256) ||
                item.Size<=0 || item.Size>MaxAssetBytes || item.Url!=expectedUrl) throw new InvalidDataException("Invalid update asset");
            actual.Add(new UpdateAsset(expectedName,item.Sha256,item.Size,expectedUrl));
        }
        var canonical=Canonical(candidate);
        if (!payload.SequenceEqual(StrictUtf8.GetBytes(canonical))) throw new InvalidDataException("Noncanonical update payload");
        if (candidate.Build <= currentBuild) throw new UpdateNotNewerException();
        return new UpdateManifest(candidate.Version,candidate.Build,candidate.Tag,candidate.SourceRevision,actual.AsReadOnly());
    }
    private static RSAParameters ReadEmbeddedKey()
    {
        var assembly=typeof(SignedUpdateVerifier).Assembly;
        using var stream=assembly.GetManifestResourceStream("MacSwitcher.Core.Resources.windows-update-public-key.json") ?? throw new InvalidDataException("Missing update trust anchor");
        if (stream.Length>4096) throw new InvalidDataException("Invalid update trust anchor");
        var key=(PublicKey)(new DataContractJsonSerializer(typeof(PublicKey)).ReadObject(stream) ?? throw new InvalidDataException("Invalid update trust anchor"));
        if (key.Modulus==null || key.Exponent==null || key.KeyId==null) throw new InvalidDataException("Invalid update trust anchor");
        byte[] modulus,exponent;
        try { modulus=DecodeBase64(key.Modulus); exponent=DecodeBase64(key.Exponent); }
        catch(FormatException error) { throw new InvalidDataException("Invalid update trust anchor",error); }
        if (modulus.Length!=384 || exponent.Length!=3 || exponent[0]!=1 || exponent[1]!=0 || exponent[2]!=1 ||
            !Regex.IsMatch(key.KeyId,"^[0-9a-f]{32}$",RegexOptions.CultureInvariant)) throw new InvalidDataException("Invalid update trust anchor");
        return new RSAParameters { Modulus=modulus,Exponent=exponent };
    }
    private static byte[] DecodeBase64(string encoded)
    {
        var result=Convert.FromBase64String(encoded);
        if (Convert.ToBase64String(result)!=encoded) throw new FormatException("Noncanonical base64");
        return result;
    }
    private static T Deserialize<T>(byte[] json)
    {
        using var memory=new MemoryStream(json,false);
        return (T)(new DataContractJsonSerializer(typeof(T)).ReadObject(memory) ?? throw new SerializationException("Missing JSON body"));
    }
    private static string Canonical(Payload payload)
    {
        // All fields are restricted to printable ASCII patterns before construction.
        var assets=payload.Assets!;
        return "{\"assets\":["+string.Join(",",assets.Select(item => "{\"name\":\""+item.Name+"\",\"sha256\":\""+item.Sha256+"\",\"size\":"+item.Size+",\"url\":\""+item.Url+"\"}"))+
            "],\"build\":"+payload.Build+",\"schema\":1,\"sourceRevision\":\""+payload.SourceRevision+"\",\"tag\":\""+payload.Tag+"\",\"version\":\""+payload.Version+"\"}";
    }
    [DataContract] private sealed class Envelope
    {
        [DataMember(Name="algorithm")] public string? Algorithm { get; set; }
        [DataMember(Name="payload")] public string? Payload { get; set; }
        [DataMember(Name="signature")] public string? Signature { get; set; }
    }
    [DataContract] private sealed class Payload
    {
        [DataMember(Name="schema")] public int Schema { get; set; }
        [DataMember(Name="version")] public string? Version { get; set; }
        [DataMember(Name="build")] public int Build { get; set; }
        [DataMember(Name="tag")] public string? Tag { get; set; }
        [DataMember(Name="sourceRevision")] public string? SourceRevision { get; set; }
        [DataMember(Name="assets")] public AssetPayload[]? Assets { get; set; }
    }
    [DataContract] private sealed class AssetPayload
    {
        [DataMember(Name="name")] public string? Name { get; set; }
        [DataMember(Name="sha256")] public string? Sha256 { get; set; }
        [DataMember(Name="size")] public long Size { get; set; }
        [DataMember(Name="url")] public string? Url { get; set; }
    }
    [DataContract] private sealed class PublicKey
    {
        [DataMember(Name="keyId")] public string? KeyId { get; set; }
        [DataMember(Name="modulus")] public string? Modulus { get; set; }
        [DataMember(Name="exponent")] public string? Exponent { get; set; }
    }
}
