using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.Json;
using MacSwitcher.Core;

static class Test
{
    static int assertions;
    static void Check(bool condition, string name)
    { assertions++; if (!condition) throw new Exception("FAIL " + name); }
    static void Equal<T>(T actual,T expected,string name) => Check(EqualityComparer<T>.Default.Equals(actual,expected),name + ": actual=" + actual + " expected=" + expected);
    static string FindRoot()
    {
        for(var directory=new DirectoryInfo(AppContext.BaseDirectory);directory!=null;directory=directory.Parent)
            if(File.Exists(Path.Combine(directory.FullName,"windows","AGENTS.md")))return directory.FullName;
        throw new Exception("Repo root not found");
    }
    static void Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--verify-update")
        {
            var signed = SignedUpdateVerifier.Verify(File.ReadAllText(args[1]), 0);
            Console.WriteLine("VERIFIED version=" + signed.Version + " build=" + signed.Build);
            return;
        }
        var root=FindRoot();
        Gesture(); Map(); Personal(); FixturePolicy(); BinaryFixtureCorruption(); ForcedWords(); SignedUpdates();
        var data=Path.Combine(root,"windows","data");
        Check(File.Exists(Path.Combine(data,"dictionary-manifest.json")),"generated dictionary required");
        using(var lex=PredictionLexicon.Load(data,new PersonalLexicon()))
        {
            Equal(lex.Frequency("привет","ru")>0,true,"frequency");
            Equal(lex.FullFrequency("привет","ru")>0,true,"full frequency");
            Equal(lex.FullFrequency("notawordzzzz","en"),0,"known absent full frequency");
            Gold(Path.Combine(data,"prediction-benchmark.json"),lex);
            RealSelectionAndPriority(lex);
        }
        Corruption(data);
        Console.WriteLine("PASS assertions="+assertions+" gold=495");
    }
    static void Gesture()
    {
        var a=new LayoutDirection("en","ru");var b=new LayoutDirection("ru","en");
        var gesture=new ShiftGesture();
        gesture.Press(ShiftSide.Left,0,a);Equal(gesture.Release(ShiftSide.Left,20)?.Kind,ShiftActionKind.SwitchLayout,"single immediate");
        gesture.Press(ShiftSide.Right,150,b);var second=gesture.Release(ShiftSide.Right,200);Equal(second?.Kind,ShiftActionKind.Convert,"cross-side double");Equal(second?.Direction.SourceId,"en","first direction captured");
        gesture.Press(ShiftSide.Right,1000,b);Equal(gesture.Release(ShiftSide.Right,1010)?.Kind,ShiftActionKind.SwitchLayout,"right switch");
        gesture.Press(ShiftSide.Right,1170,a);Equal(gesture.Release(ShiftSide.Right,1190)?.Kind,ShiftActionKind.Convert,"180 boundary");
        gesture.Press(ShiftSide.Left,2000,a);Equal(gesture.Release(ShiftSide.Left,2005)?.Kind,ShiftActionKind.SwitchLayout,"first separated");
        gesture.Press(ShiftSide.Left,2180,a);Equal(gesture.Release(ShiftSide.Left,2186)?.Kind,ShiftActionKind.SwitchLayout,"beyond boundary");
        gesture.Press(ShiftSide.Left,3000,a);gesture.Press(ShiftSide.Right,3001,b);Equal(gesture.Release(ShiftSide.Left,3020),null,"chord refused");
        gesture.Press(ShiftSide.Left,4000,a);Equal(gesture.Release(ShiftSide.Left,4300),null,"hold refused");
        gesture.Press(ShiftSide.Left,5000,a);gesture.Interrupt();Equal(gesture.Release(ShiftSide.Left,5010),null,"interrupted");
        gesture.Press(ShiftSide.Right,6000,b);Equal(gesture.Release(ShiftSide.Right,6010)?.Kind,ShiftActionKind.SwitchLayout,"repeat after interrupt");
    }
    static void Map()
    {
        Equal(LayoutMap.Convert("ghbdtn","en"),"привет","layout en ru");
        Equal(LayoutMap.Convert("руддщ","ru"),"hello","layout ru en");
        Equal(LayoutMap.ConvertBidirectional("ghbdtn мир"),"привет vbh","mixed bidirectional");
        Equal(LayoutMap.Convert("to\\","en"),"ещё","yo physical");
        Equal(LayoutMap.Convert("hello","he"),"hello","unsupported language");
    }
    static void Personal()
    {
        var lex=new PersonalLexicon();lex.AddWord("ChatGPT","en");lex.AddPhraseException("ghbdtn", "en");
        Check(lex.IsWord("chatgpt","en"),"personal word");Check(lex.IsPhraseException("ghbdtn","en"),"phrase exception");
        var snapshot=lex.ExportSnapshot();var second=new PersonalLexicon();second.ReplaceSnapshot(snapshot);
        Check(second.IsWord("chatgpt","en")&&second.IsPhraseException("ghbdtn","en"),"snapshot replace");
        second.RemoveWord("ChatGPT","en");Check(!second.IsWord("chatgpt","en"),"word removal");
    }
    static void FixturePolicy()
    {
        using var lex=PredictionLexicon.FromFixture(new Dictionary<string,Dictionary<string,int>> {
            ["ru"]=new() { ["привет"]=100000,["могу"]=50000,["стоит"]=10000 },["en"]=new() { ["press"]=10000,["iphone"]=10000 } });
        var engine=new PredictionEngine(lex);
        Equal(engine.Evaluate("press ghbdtn","en",true)?.ReplacementSuffix,"press привет","bounded suffix");
        Equal(engine.Evaluate("press f","en",true,truePreceding())?.ReplacementSuffix,null,"technical context");
        Equal(engine.Evaluate("foo@example.com","en",true)?.ReplacementSuffix,null,"address protected");
        Equal(engine.Evaluate("C:\\file\\ghbdtn","en",true)?.ReplacementSuffix,null,"path protected");
        Equal(engine.Evaluate("GHBDTN","en",true)?.ReplacementSuffix,null,"caps protected");
        Equal(SelectionConverter.Convert("ghbdtn iPhone стоит",lex,true,"en"),"привет iPhone стоит","smart mixed selection");
        Equal(SelectionConverter.Convert("ghbdtn",lex,false,"en"),"привет","manual full flip");
        Equal(SelectionConverter.Convert("ghbdtn мир",lex,false,"en"),"привет vbh","bidirectional full flip");
        Equal(SelectionConverter.Convert("f to\\",lex,true,"en",true),"а ещё","priority exact selection");
    }
    static string[] truePreceding()=>Array.Empty<string>();
    static void Gold(string path,PredictionLexicon lex)
    {
        using var doc=JsonDocument.Parse(File.ReadAllText(path));var cases=doc.RootElement.GetProperty("cases").EnumerateArray().ToArray();
        Equal(cases.Length,495,"gold case count");
        var engine=new PredictionEngine(lex);var fails=new List<string>();
        foreach(var item in cases)
        {
            var id=item.GetProperty("id").GetString()!;var input=item.GetProperty("input").GetString()!;
            var language=item.GetProperty("sourceLanguage").GetString()!;var boundary=item.GetProperty("atBoundary").GetBoolean();
            var preceding=item.GetProperty("precedingWords").EnumerateArray().Select(x=>x.GetString()!).ToArray();
            var expectedNode=item.GetProperty("expectedReplacement");var expected=expectedNode.ValueKind==JsonValueKind.Null?null:expectedNode.GetString();
            var actual=engine.Evaluate(input,language,boundary,preceding)?.ReplacementSuffix;
            if(actual!=expected) fails.Add(id+" actual="+actual+" expected="+expected);
        }
        if(fails.Count>0)throw new Exception("Gold failures="+fails.Count+"\n"+string.Join("\n",fails.Take(40)));
        assertions+=cases.Length;
    }



    static void ForcedWords()
    {
        using var lex=PredictionLexicon.FromFixture(new Dictionary<string,Dictionary<string,int>> {
            ["en"]=new() { ["rfr"]=1000 }, ["ru"]=new() { ["как"]=10000 } });
        var engine=new PredictionEngine(lex);
        Equal(engine.Evaluate("rfr ","en",true)?.ReplacementSuffix,null,"known source remains without force");
        Equal(engine.Evaluate("rfr ","en",true,alwaysConvertWords:new[]{"как"})?.ReplacementSuffix,"как ","force overrides source frequency at boundary");
        Equal(engine.Evaluate("rfr","en",false,alwaysConvertWords:new[]{"как"})?.ReplacementSuffix,null,"force only at boundary");
        Equal(engine.Evaluate("foo@example.com ","en",true,alwaysConvertWords:new[]{"ащщ@учфьзду/сщь"})?.ReplacementSuffix,null,"force cannot bypass address");
        Equal(engine.Evaluate("C:\\rfr ","en",true,alwaysConvertWords:new[]{"как"})?.ReplacementSuffix,null,"force cannot bypass path");
        var settings=new AppSettings { AlwaysConvertWords=new[]{"как"} };settings.Validate();
        Check(!settings.SmartSelection,"owner default full selection flip");
        Check(settings.AlwaysConvertWords.Length==1,"forced settings retained");
    }
    static void SignedUpdates()
    {
        Reject(()=>SignedUpdateVerifier.Verify("{}",0),"embedded trust anchor available and invalid envelope refused");
        using var signing=RSA.Create(2048);using var other=RSA.Create(2048);
        var key=signing.ExportParameters(false);var otherKey=other.ExportParameters(false);
        var payload=UpdatePayload();var envelope=SignEnvelope(payload,signing);
        var result=SignedUpdateVerifier.VerifyWithKey(envelope,1,key);
        Equal(result.Version,"0.1.0-alpha.2","signed version");
        Equal(result.Build,2,"signed build");
        Equal(result.Assets.Count,2,"signed asset count");
        Check(result.Assets[0].DownloadUrl.StartsWith("https://github.com/alexfisenkov/MacSwitcher/releases/download/",StringComparison.Ordinal),"trusted download origin");
        Reject(()=>SignedUpdateVerifier.VerifyWithKey(envelope,2,key),"rollback build");
        Reject(()=>SignedUpdateVerifier.VerifyWithKey(envelope,1,otherKey),"wrong signing key");
        var tampered=envelope.Replace("RSA-SHA256","RSA-SHA1");
        Reject(()=>SignedUpdateVerifier.VerifyWithKey(tampered,1,key),"algorithm tamper");
        Reject(()=>SignedUpdateVerifier.VerifyWithKey(SignEnvelope(UpdatePayload(size:536870913),signing),1,key),"asset oversize");
        Reject(()=>SignedUpdateVerifier.VerifyWithKey(SignEnvelope(UpdatePayload(name:"../Setup.exe"),signing),1,key),"asset path traversal");
        Reject(()=>SignedUpdateVerifier.VerifyWithKey(SignEnvelope(UpdatePayload(version:"0.1.0-alpha.2",tag:"windows-v0.1.0-alpha.3"),signing),1,key),"tag mismatch");
        Reject(()=>SignedUpdateVerifier.VerifyWithKey(SignEnvelope(UpdatePayload(schema:2),signing),1,key),"unknown schema");
        Reject(()=>SignedUpdateVerifier.VerifyWithKey(envelope.Substring(0,envelope.Length-2)+"}",1,key),"broken envelope");
    }
    static string UpdatePayload(long size=100,string? name=null,string version="0.1.0-alpha.2",string? tag=null,int schema=1)
    {
        tag ??="windows-v"+version;
        var setup=name??"MacSwitcher-Windows-"+version+"-Setup.exe";
        var zip="MacSwitcher-Windows-"+version+"-portable.zip";
        var url="https://github.com/alexfisenkov/MacSwitcher/releases/download/"+tag+"/";
        var sha=new string('a',64);var revision=new string('b',40);
        return "{\"assets\":[{\"name\":\""+setup+"\",\"sha256\":\""+sha+"\",\"size\":"+size+",\"url\":\""+url+setup+"\"},{\"name\":\""+zip+"\",\"sha256\":\""+sha+"\",\"size\":200,\"url\":\""+url+zip+"\"}],\"build\":2,\"schema\":"+schema+",\"sourceRevision\":\""+revision+"\",\"tag\":\""+tag+"\",\"version\":\""+version+"\"}";
    }
    static string SignEnvelope(string payload,RSA rsa)
    {
        var bytes=Encoding.UTF8.GetBytes(payload);var signature=rsa.SignData(bytes,HashAlgorithmName.SHA256,RSASignaturePadding.Pkcs1);
        return "{\"algorithm\":\"RSA-SHA256\",\"payload\":\""+Convert.ToBase64String(bytes)+"\",\"signature\":\""+Convert.ToBase64String(signature)+"\"}";
    }
    static void Reject(Action action,string name)
    {
        var rejected=false;try{action();}catch(InvalidDataException){rejected=true;}catch(UpdateNotNewerException){rejected=true;}catch(CryptographicException){rejected=true;}catch(System.Runtime.Serialization.SerializationException){rejected=true;}
        Check(rejected,name);
    }

    static void RealSelectionAndPriority(PredictionLexicon lex)
    {
        var engine=new PredictionEngine(lex);
        Equal(engine.Evaluate("nfr ","en",true,russianPriority:true)?.ReplacementSuffix,"так ","alpha24 boundary так");
        Equal(engine.Evaluate("b ","en",true,new[]{"так"},true)?.ReplacementSuffix,"и ","alpha24 boundary и");
        Equal(engine.Evaluate("j,sxyj ","en",true,new[]{"так","и"},true)?.ReplacementSuffix,"обычно ","alpha24 boundary обычно");
        Equal(engine.Evaluate("nfr","en",false,russianPriority:true)?.ReplacementSuffix,null,"alpha24 early nfr abstain");
        Equal(engine.Evaluate("b","en",false,new[]{"так"},true)?.ReplacementSuffix,"и","alpha24 early и");
        Equal(engine.Evaluate("j,sxyj","en",false,new[]{"так","и"},true)?.ReplacementSuffix,"обычно","alpha24 early обычно");
        Equal(SelectionConverter.Convert("ghbdtn MacSwitcher",lex,true,"en"),"привет MacSwitcher","real selection brand");
        Equal(SelectionConverter.Convert("MacSwitcher levf. xnj-nj nfrjt",lex,true,"en"),"MacSwitcher думаю что-то такое","real selection phrase");
        Equal(SelectionConverter.Convert("nfr b j,sxyj",lex,true,"en",true),"nfr и обычно","real selection priority");
    }

    static void BinaryFixtureCorruption()
    {
        var temp=Path.Combine(Path.GetTempPath(),"mscore-small-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(temp);
        try
        {
            File.WriteAllText(Path.Combine(temp,"ru.tsv"),"привет\t50000\n");
            File.WriteAllText(Path.Combine(temp,"en.tsv"),"hello\t50000\n");
            File.WriteAllText(Path.Combine(temp,"protected-terms.tsv"),"");
            WriteLex(Path.Combine(temp,"ru.lex"),"привет",50000);
            WriteLex(Path.Combine(temp,"en.lex"),"hello",50000);
            Manifest(temp);
            using(var valid=PredictionLexicon.Load(temp,new PersonalLexicon())) Equal(valid.FullFrequency("hello","en"),50000,"binary fixture valid");
            var path=Path.Combine(temp,"en.lex");
            using(var stream=File.Open(path,FileMode.Open,FileAccess.Write,FileShare.None)) { stream.Position=24+2+"hello".Length; stream.WriteByte(0); }
            Manifest(temp);
            var rejected=false;try{using var invalid=PredictionLexicon.Load(temp,new PersonalLexicon());}catch(InvalidDataException){rejected=true;}
            Check(rejected,"binary bad index offset rejected with valid hash");
            WriteLex(path,"hello",50000);
            using(var stream=File.Open(path,FileMode.Open,FileAccess.Write,FileShare.None)) { stream.Position=24+2+"hello".Length+8+4+2; stream.WriteByte(0xff); }
            Manifest(temp);
            rejected=false;try{using var invalid=PredictionLexicon.Load(temp,new PersonalLexicon());}catch(DecoderFallbackException){rejected=true;}catch(InvalidDataException){rejected=true;}
            Check(rejected,"binary malformed UTF8 rejected with valid hash");
        }
        finally { Directory.Delete(temp,true); }
    }
    static void WriteLex(string path,string word,int frequency)
    {
        var bytes=Encoding.UTF8.GetBytes(word);
        using var stream=File.Create(path);using var writer=new BinaryWriter(stream,Encoding.UTF8,true);
        writer.Write(Encoding.ASCII.GetBytes("MSLEXW01"));writer.Write(128u);writer.Write(1u);writer.Write(1ul);
        writer.Write((ushort)bytes.Length);writer.Write(bytes);writer.Write((long)(24+2+bytes.Length+8+4));writer.Write(1u);
        writer.Write((ushort)bytes.Length);writer.Write(bytes);writer.Write(frequency);writer.Write((byte)0);
    }
    static void Manifest(string directory)
    {
        var files=new JsonObject();
        foreach(var name in new[]{"ru.tsv","en.tsv","protected-terms.tsv","ru.lex","en.lex"})
        {
            var path=Path.Combine(directory,name);using var sha=SHA256.Create();using var stream=File.OpenRead(path);
            files[name]=new JsonObject{["sha256"]=Convert.ToHexString(sha.ComputeHash(stream)).ToLowerInvariant(),["size"]=new FileInfo(path).Length};
        }
        File.WriteAllText(Path.Combine(directory,"dictionary-manifest.json"),new JsonObject{["files"]=files}.ToJsonString());
    }

    static void Corruption(string data)
    {
        var temp=Path.Combine(Path.GetTempPath(),"mscore-test-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(temp);
        try
        {
            foreach(var name in new[]{"dictionary-manifest.json","ru.tsv","en.tsv","protected-terms.tsv","ru.lex","en.lex"})File.Copy(Path.Combine(data,name),Path.Combine(temp,name));
            using(var file=File.Open(Path.Combine(temp,"en.lex"),FileMode.Open,FileAccess.Write,FileShare.None)){file.Position=0;file.WriteByte(0);}
            var rejected=false;try{using var lex=PredictionLexicon.Load(temp,new PersonalLexicon());}catch(InvalidDataException){rejected=true;}
            Check(rejected,"hash corruption rejected");
        }
        finally{Directory.Delete(temp,true);}
    }
}
