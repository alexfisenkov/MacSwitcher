using System;
using System.IO;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Threading.Tasks;
using System.Threading;
using MacSwitcher.Core;

namespace MacSwitcher.Windows.Storage;

// All mutations serialize through gate. A callback only queues work and captures an epoch.
public sealed class AdaptiveRulesStore
{
    private const int MaximumBytes=512*1024;
    private readonly object gate=new object();
    private readonly object queueGate=new object();
    private readonly string path;
    private readonly Action? beforeWrite;
    private readonly Action? beforeCleanup;
    private long epoch;
    private bool accepting;
    private readonly Queue<Pending> pending=new Queue<Pending>();
    private readonly HashSet<string> cleanupPending=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
    private bool draining;
    private sealed class Pending { public AdaptiveEvent Change=null!; public long Epoch; }
    private bool writable=true;
    public AdaptiveLearning Learning { get; }=new AdaptiveLearning();
    public bool CanWrite { get { lock(gate) return writable; } }
    internal bool FixtureAccepting => Volatile.Read(ref accepting);
    internal bool FixtureIdle { get { lock(queueGate) return pending.Count==0 && !draining; } }
    public string Problem { get; private set; }="";
    public string CleanupProblem { get; private set; }="";
    public AdaptiveRulesStore(string directory) : this(directory,null) { }
    internal AdaptiveRulesStore(string directory,Action? beforeWrite,Action? beforeCleanup=null)
    { path=Path.Combine(directory,"adaptive-rules.json"); this.beforeWrite=beforeWrite; this.beforeCleanup=beforeCleanup; }
    public void Load(bool enabled)
    {
        Volatile.Write(ref accepting,false);
        lock(gate)
        {
            Interlocked.Increment(ref epoch);
            try
            {
                Learning.Replace(File.Exists(path)?Read(path).Rules:Array.Empty<AdaptiveRule>());
                writable=true; Problem="";
                RetryOwnCleanup(File.Exists(path));
                if(cleanupPending.Any(x=>IsOwnTransient(x,"rollback")))
                {
                    writable=false;
                    Problem="Обнаружена резервная копия после незавершённого сохранения. Файлы сохранены; обучение выключено до восстановления в настройках.";
                }
            }
            catch
            {
                writable=false;
                Problem="Файл выученных правил не читается или создан другой версией. Он сохранён без изменений; обучение выключено.";
                Learning.Replace(Array.Empty<AdaptiveRule>());
            }
            Learning.SetEnabled(enabled && writable);
            Volatile.Write(ref accepting,enabled && writable);
        }
    }
    public void SetEnabled(bool enabled)
    {
        Volatile.Write(ref accepting,false);
        lock(gate)
        {
            Interlocked.Increment(ref epoch);
            Learning.SetEnabled(enabled && writable);
            Volatile.Write(ref accepting,enabled && writable);
        }
    }
    public string[] RecoverUnreadable(bool enabled)
    {
        Volatile.Write(ref accepting,false);
        lock(gate)
        {
            Interlocked.Increment(ref epoch);
            if(writable) { Volatile.Write(ref accepting,Learning.Enabled); return Array.Empty<string>(); }
            var preserved=new List<string>();
            if(File.Exists(path))
            {
                var copy=path+".recovery-"+DateTime.UtcNow.ToString("yyyyMMdd-HHmmss")+"-"+Guid.NewGuid().ToString("N")+".json";
                File.Move(path,copy); preserved.Add(copy);
            }
            var directory=Path.GetDirectoryName(path)!;
            if(Directory.Exists(directory)) foreach(var file in Directory.GetFiles(directory,"adaptive-rules.json.*"))
                if(IsOwnTransient(file))
                {
                    var copy=file+".recovery-"+Guid.NewGuid().ToString("N")+".json";
                    File.Move(file,copy); preserved.Add(copy);
                }
            cleanupPending.Clear(); RefreshCleanupProblem();
            Learning.Reset(); writable=true; Problem=""; Learning.SetEnabled(enabled);
            Volatile.Write(ref accepting,enabled);
            return preserved.ToArray();
        }
    }
    public void Submit(AdaptiveEvent change)
    {
        if(!Volatile.Read(ref accepting)) return;
        if(!change.SourceConfirmed || !AdaptiveLearning.TryPair(change.Original,change.Replacement,out _,out _)) return;
        var captured=Interlocked.Read(ref epoch);
        lock(queueGate)
        {
            if(!Volatile.Read(ref accepting) || captured!=Interlocked.Read(ref epoch)) return;
            if(pending.Count>=256) return;
            pending.Enqueue(new Pending { Change=change,Epoch=captured });
            if(draining) return;
            draining=true;
        }
        _=Task.Run(Drain);
    }
    private void Drain()
    {
        while(true)
        {
            Pending item;
            lock(queueGate)
            {
                if(pending.Count==0) { draining=false; return; }
                item=pending.Dequeue();
            }
            lock(gate)
            {
                if(item.Epoch!=Interlocked.Read(ref epoch) || !Volatile.Read(ref accepting) ||
                    !writable || !Learning.Enabled ||
                    !Learning.TryApply(item.Change,DateTime.UtcNow,out var next)) continue;
                try
                {
                    Save(next);
                    if(item.Epoch==Interlocked.Read(ref epoch)) Learning.Commit(item.Change,next);
                }
                catch(Exception)
                {
                    if(writable)
                    {
                        writable=false;
                        Learning.SetEnabled(false);
                        Volatile.Write(ref accepting,false);
                        Problem="Не удалось сохранить выученные правила. Обучение выключено; проверьте локальный файл и доступ к папке.";
                    }
                    Interlocked.Increment(ref epoch);
                }
            }
        }
    }
    public AdaptiveRule[] Snapshot()=>Learning.Snapshot();
    public void Delete(string english,string russian)
    {
        Volatile.Write(ref accepting,false);
        lock(gate)
        {
            Interlocked.Increment(ref epoch);
            try
            {
                EnsureWritable();
                var next=Learning.Snapshot().Where(x=>x.English!=english||x.Russian!=russian).ToArray();
                Save(next); Learning.Delete(english,russian);
                RetryOwnCleanup();
            }
            finally { Volatile.Write(ref accepting,writable && Learning.Enabled); }
        }
    }
    public void Reset()
    {
        Volatile.Write(ref accepting,false);
        lock(gate)
        {
            Interlocked.Increment(ref epoch);
            try { EnsureWritable(); Save(Array.Empty<AdaptiveRule>()); Learning.Reset(); RetryOwnCleanup(true,true); }
            finally { Volatile.Write(ref accepting,writable && Learning.Enabled); }
        }
    }
    private void EnsureWritable()
    { if(!writable) throw new InvalidOperationException(Problem); }
    [DataContract]
    private sealed class Document
    {
        [DataMember(Order=1)] public int Schema { get; set; }=1;
        [DataMember(Order=2)] public AdaptiveRule[] Rules { get; set; }=Array.Empty<AdaptiveRule>();
    }
    private static Document Read(string file)
    {
        if(new FileInfo(file).Length>MaximumBytes) throw new InvalidDataException();
        using var stream=new FileStream(file,FileMode.Open,FileAccess.Read,FileShare.Read);
        var doc=(Document)(new DataContractJsonSerializer(typeof(Document)).ReadObject(stream)??throw new SerializationException());
        if(doc.Schema!=1 || doc.Rules==null) throw new SerializationException();
        AdaptiveLearning.Validate(doc.Rules);
        return doc;
    }
    private void Save(AdaptiveRule[] rules)
    {
        AdaptiveLearning.Validate(rules);
        beforeWrite?.Invoke();
        var directory=Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        var temp=path+".tmp-"+Guid.NewGuid().ToString("N");
        var rollback=path+".rollback-"+Guid.NewGuid().ToString("N");
        var existed=File.Exists(path);
        var committed=false;
        try
        {
            using(var stream=new FileStream(temp,FileMode.CreateNew,FileAccess.Write,FileShare.None))
            {
                new DataContractJsonSerializer(typeof(Document)).WriteObject(stream,new Document{Rules=rules});
                stream.Flush(true);
                if(stream.Length>MaximumBytes) throw new InvalidDataException("Adaptive rules exceed 512 KiB");
            }
            RestrictFile(temp);
            Read(temp);
            var before=Hash(temp);
            if(existed) File.Replace(temp,path,rollback); else File.Move(temp,path);
            RestrictFile(path);
            Read(path);
            if(before!=Hash(path)) throw new IOException("Adaptive rules read-back mismatch");
            committed=true;
        }
        catch
        {
            var rollbackConfirmed=true;
            if(existed && File.Exists(rollback))
            { try { File.Replace(rollback,path,null); } catch { rollbackConfirmed=false; } }
            else if(!existed && File.Exists(path))
            { try { File.Delete(path); } catch { rollbackConfirmed=false; } }
            if(!rollbackConfirmed)
            {
                writable=false;
                Learning.SetEnabled(false);
                Volatile.Write(ref accepting,false);
                Problem="Сохранение выученных правил не подтверждено. Резервная копия сохранена; обучение выключено.";
            }
            throw;
        }
        finally
        {
            Cleanup(temp);
            if(committed) Cleanup(rollback,true);
        }
    }
    private void Cleanup(string file,bool committedBackup=false)
    {
        try
        {
            if(File.Exists(file)) { beforeCleanup?.Invoke(); File.Delete(file); }
            cleanupPending.Remove(file);
        }
        catch
        {
            if(committedBackup && IsOwnTransient(file,"rollback") && File.Exists(file))
            {
                var safeName=Path.Combine(Path.GetDirectoryName(file)!,
                    Path.GetFileName(file).Replace(".rollback-",".cleanup-"));
                try { File.Move(file,safeName); file=safeName; } catch { }
            }
            if(File.Exists(file)) cleanupPending.Add(file);
        }
        RefreshCleanupProblem();
    }
    private void RetryOwnCleanup(bool safeToDelete=true,bool includeRollback=false)
    {
        var directory=Path.GetDirectoryName(path)!;
        if(!Directory.Exists(directory)) { cleanupPending.Clear(); RefreshCleanupProblem(); return; }
        try
        {
            foreach(var file in Directory.GetFiles(directory,"adaptive-rules.json.*"))
                if(IsOwnTransient(file))
                {
                    if(safeToDelete && (includeRollback || !IsOwnTransient(file,"rollback"))) Cleanup(file);
                    else cleanupPending.Add(file);
                }
        }
        catch { CleanupProblem="Не удалось проверить временные копии выученных правил в локальной папке."; return; }
        cleanupPending.RemoveWhere(file=>!File.Exists(file));
        RefreshCleanupProblem();
    }
    private static bool IsOwnTransient(string file)
    {
        return IsOwnTransient(file,"tmp") || IsOwnTransient(file,"rollback") || IsOwnTransient(file,"cleanup");
    }
    private static bool IsOwnTransient(string file,string kind)
    {
        var name=Path.GetFileName(file);
        var prefix="adaptive-rules.json."+kind+"-";
        return name.StartsWith(prefix,StringComparison.Ordinal) && name.Length==prefix.Length+32 &&
            name.Substring(prefix.Length).All(Uri.IsHexDigit);
    }
    private void RefreshCleanupProblem()
    {
        CleanupProblem=cleanupPending.Count==0?"":
            cleanupPending.Any(x=>IsOwnTransient(x,"rollback"))?
            "Осталась копия после незавершённой записи. Сохраните проблемные файлы через восстановление в настройках.":
            "Правила изменены, но локальная резервная копия старых правил ещё не удалена. Повторите сброс после проверки доступа к папке.";
    }
    private static void RestrictFile(string file)
    {
        var user=WindowsIdentity.GetCurrent().User??throw new UnauthorizedAccessException();
        var security=new FileSecurity(); security.SetAccessRuleProtection(true,false);
        security.AddAccessRule(new FileSystemAccessRule(user,FileSystemRights.FullControl,AccessControlType.Allow));
        File.SetAccessControl(file,security);
    }
    private static string Hash(string file)
    { using var stream=File.OpenRead(file); using var hash=SHA256.Create(); return BitConverter.ToString(hash.ComputeHash(stream)); }
}
