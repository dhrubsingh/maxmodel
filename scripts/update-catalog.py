#!/usr/bin/env python3
"""Build the bundled, reviewed catalog and preserve publisher licenses/attributions.
No model repository code is executed. The app never runs this maintainer script.
Existing weight revisions stay pinned unless --refresh-weights is requested.
"""
import argparse, concurrent.futures, hashlib, io, json, pathlib, re, shutil, struct, tempfile, time, urllib.request
from html.parser import HTMLParser

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPECS = json.loads((ROOT / 'scripts/catalog-specs.json').read_text())
KNOWLEDGE = json.loads((ROOT / 'scripts/model-knowledge.json').read_text())
CACHE = ROOT / '.test-data/catalog-metadata'
LICENSE_NAMES = {'apache-2.0':'Apache-2.0', 'mit':'MIT', 'llama3.1':'Llama 3.1 Community',
                 'llama3.2':'Llama 3.2 Community', 'llama3.3':'Llama 3.3 Community',
                 'gemma':'Gemma Terms', 'qwen-research':'Qwen Research', 'lfm1.0':'LFM Open License 1.0',
                 'falcon-llm-license':'Falcon LLM License', 'deepseek-license':'DeepSeek Model License'}
TESTED = {'qwen3-4b','qwen3-06b','qwen3-17b','smollm3-3b','phi4-mini','ministral3-3b','qwen35-08','smollm2-135m','granite33-2b','deepseek-r1-15b','gemma4-e2b','olmo2-7b'}
ARCH_URL = 'https://raw.githubusercontent.com/ggml-org/llama.cpp/b11146/src/llama-arch.cpp'

def read(url, limit=None, headers=None):
    for attempt in range(3):
        try:
            req=urllib.request.Request(url, headers={'User-Agent':'MaxModel-Catalog-Builder/0.2', **(headers or {})})
            with urllib.request.urlopen(req, timeout=60) as r: return r.read(limit)
        except Exception:
            if attempt == 2: raise
            time.sleep(.25 * (attempt+1))

def metadata(repo, cached):
    path=CACHE/(repo.replace('/','__')+'.json')
    if cached and path.exists(): return json.loads(path.read_text())
    data=read(f'https://huggingface.co/api/models/{repo}?blobs=true')
    path.write_bytes(data)
    return json.loads(data)

def vision_encoder(repo, revision, cached):
    """The publisher's F16 projector, pinned to the weights' revision, if the release has one."""
    path=CACHE/(repo.replace('/','__')+'@'+revision+'.json')
    if cached and path.exists(): meta=json.loads(path.read_text())
    else:
        data=read(f'https://huggingface.co/api/models/{repo}/revision/{revision}?blobs=true');path.write_bytes(data);meta=json.loads(data)
    files=[x for x in meta['siblings'] if x['rfilename'].lower()=='mmproj-f16.gguf']
    if not files: return None
    f=files[0]
    return dict(filename=f['rfilename'],bytes=f['size'],sha256=f['lfs']['sha256'],url=f"https://huggingface.co/{repo}/resolve/{revision}/{f['rfilename']}")

def gguf_header(url):
    raw=read(url,65536,{'Range':'bytes=0-65535'})
    stream=io.BytesIO(raw)
    def scalar(fmt): return struct.unpack('<'+fmt,stream.read(struct.calcsize('<'+fmt)))[0]
    def string():
        n=scalar('Q'); data=stream.read(n)
        if len(data)!=n: raise EOFError()
        return data.decode()
    def value(kind):
        fmt={0:'B',1:'b',2:'H',3:'h',4:'I',5:'i',6:'f',7:'?',10:'Q',11:'q',12:'d'}
        if kind in fmt: return scalar(fmt[kind])
        if kind==8: return string()
        if kind==9:
            subtype,count=scalar('I'),scalar('Q')
            if count>4096: raise EOFError() # Vocabulary arrays follow architecture metadata.
            return [value(subtype) for _ in range(count)]
        raise ValueError(f'Unknown GGUF value type {kind}')
    if stream.read(4)!=b'GGUF': raise ValueError('The pinned download is not GGUF')
    version=scalar('I'); scalar('Q'); count=scalar('Q')
    if version not in (2,3): raise ValueError('Unsupported GGUF version')
    result={}
    try:
        for _ in range(count):
            key=string(); result[key]=value(scalar('I'))
    except (EOFError,struct.error): pass
    return result

class ReadableHTML(HTMLParser):
    def __init__(self): super().__init__(); self.parts=[]; self.hidden=0
    def handle_starttag(self,tag,attrs):
        if tag in ('script','style','svg'): self.hidden+=1
        if tag in ('p','div','h1','h2','h3','li','br','section'): self.parts.append('\n')
    def handle_endtag(self,tag):
        if tag in ('script','style','svg'): self.hidden=max(0,self.hidden-1)
        if tag in ('p','div','h1','h2','h3','li','section'): self.parts.append('\n')
    def handle_data(self,data):
        if not self.hidden: self.parts.append(data)
    def text(self): return re.sub(r'\n[ \t]*\n(?:[ \t]*\n)+','\n\n',''.join(self.parts)).strip()

def without_scripts(html):
    """License pages are saved as documents, not apps. Their site scripts carry the host's
    public browser API keys, which secret scanners report as leaks."""
    return re.sub(rb'<script\b[^>]*>.*?</script\s*>', b'', html, flags=re.S | re.I)

def notices(spec, meta, license_id):
    source=spec['source']; revision=meta['sha']; card=meta.get('cardData',{})
    files={x['rfilename'] for x in meta['siblings']}
    paths=sorted(f for f in files if '/' not in f and (f.lower().startswith(('license','notice')) or f.lower() in ('use_policy.md','acceptable_use_policy.md')))
    docs=[]
    for path in paths:
        url=f'https://huggingface.co/{source}/resolve/{revision}/{path}'
        if spec['family']=='Llama' and path=='USE_POLICY.md':
            version=license_id.replace('.', '_')
            url=f'https://raw.githubusercontent.com/meta-llama/llama-models/0e0b8c519242d5833d8c11bffc1232b77ad7f301/models/{version}/USE_POLICY.md'
        docs.append((path,read(url),url))
    if not any(name.lower().startswith('license') for name,_,_ in docs):
        if license_id=='apache-2.0': url='https://www.apache.org/licenses/LICENSE-2.0.txt'
        elif license_id=='gemma': url='https://ai.google.dev/gemma/terms'
        elif license_id=='deepseek-license': url='https://raw.githubusercontent.com/deepseek-ai/DeepSeek-Coder-V2/main/LICENSE-MODEL'
        elif card.get('license_link','').startswith('https://'): url=card['license_link']
        else: raise ValueError(f'{source}: no original license document')
        data=read(url); suffix='html' if b'<html' in data[:1000].lower() or b'<!doctype html' in data[:1000].lower() else 'txt'
        docs.insert(0,(f'LICENSE.{suffix}',without_scripts(data) if suffix=='html' else data,url))
    if license_id=='gemma':
        url='https://ai.google.dev/gemma/prohibited_use_policy';docs.append(('USE_POLICY.html',without_scripts(read(url)),url))
    if 'README.md' in files:
        url=f'https://huggingface.co/{source}/resolve/{revision}/README.md';docs.append(('MODEL_CARD.md',read(url),url))
    if spec.get('baseSource'):
        base=spec['baseSource'];base_meta=metadata(base,True)
        for filename in ['LICENSE','README.md']:
            url=f"https://huggingface.co/{base}/resolve/{base_meta['sha']}/{filename}"
            if filename=='LICENSE' and not any(f['rfilename']=='LICENSE' for f in base_meta['siblings']):
                if base_meta.get('cardData',{}).get('license')!='apache-2.0': raise ValueError('Missing base-model license')
                url='https://www.apache.org/licenses/LICENSE-2.0.txt'
            docs.append(('BASE_MODEL_'+filename,read(url),url))
    primary=next(d for d in docs if d[0].lower().startswith('license'))
    license_text=primary[1].decode('utf-8')
    if spec['family']=='Llama':
        notice=re.search(r'[“"]([^”"]*is\s+licensed under[^”"]*All Rights\s+Reserved\.?)[”"]',license_text)
        if not notice: raise ValueError('Missing required Llama attribution notice')
        docs.append(('NOTICE.txt',(notice.group(1)+'\n').encode(),primary[2]))
    if primary[0].endswith('.html'):
        parser=ReadableHTML();parser.feed(license_text);license_text=parser.text()
    docs.append(('TERMS-READABLE.txt',license_text.encode(),primary[2]))
    digest=hashlib.sha256(b''.join(data for name,data,_ in docs if name!='MODEL_CARD.md')).hexdigest()
    return docs,primary[2],digest

def fetch(spec, old, cached, refresh, supported):
    source,repo=spec['source'],spec['distributor']
    author=metadata(source,cached);quant=metadata(repo,cached)
    card=author.get('cardData',{});license_id=card.get('license')
    quant_license=quant.get('cardData',{}).get('license')
    if not license_id or quant_license not in (None,license_id): raise ValueError(f'{repo}: license mismatch {license_id}/{quant_license}')
    if license_id=='other': license_id=card.get('license_name')
    if license_id not in LICENSE_NAMES: raise ValueError(f'{source}: unreviewed license {license_id}')
    label=LICENSE_NAMES[license_id]
    prior=old.get(spec['id'])
    if prior and not refresh:
        filename,url,size,sha=prior['filename'],prior['url'],prior['bytes'],prior['sha256'];quantization=prior['quantization']
    else:
        # A spec may pin another precision so one model can fit several memory tiers.
        quantization=spec.get('quantization') or ('MXFP4' if spec['family']=='gpt-oss' else 'Q4_K_M')
        suffix=('-' if spec.get('quantization') else '')+quantization+'.GGUF'
        candidates=[x for x in quant['siblings'] if x['rfilename'].upper().endswith(suffix.upper())]
        if len(candidates)!=1: raise ValueError(f'{repo}: expected one {quantization} file, got {len(candidates)}')
        f=candidates[0];filename=f['rfilename'];size=f['size'];sha=f['lfs']['sha256']
        if '/' in filename: raise ValueError(f'{repo}: sharded models need a separate downloader review')
        url=f"https://huggingface.co/{repo}/resolve/{quant['sha']}/{filename}"
        if 'UD-Q4_K_M' in filename and not spec.get('quantization'): quantization='UD-Q4_K_M'
    header_path=CACHE/(sha+'.header.json')
    if header_path.exists(): header=json.loads(header_path.read_text())
    else: header=gguf_header(url);header_path.write_text(json.dumps(header))
    arch=header.get('general.architecture')
    if arch not in supported: raise ValueError(f'{source}: engine b11146 does not support {arch}')
    def number(key, default=None):
        v=header.get(arch+'.'+key,default)
        return max(v) if isinstance(v,list) else v
    layers=number('block_count');heads=number('attention.head_count');kv=number('attention.head_count_kv',heads)
    key=number('attention.key_length',number('embedding_length')//max(1,heads));value=number('attention.value_length',key)
    if not all(v and v>0 for v in [layers,heads,kv,key,value]): raise ValueError(f'{source}: cannot derive memory estimate')
    kv_bytes=int(layers*kv*(key+value)*2) # Conservative full-attention FP16 cache estimate.
    docs,license_url,license_digest=notices(spec,author,license_id)
    vision=vision_encoder(repo,re.search(r'/resolve/([0-9a-f]{40})/',url)[1],cached)
    name=spec.get('name',spec['series']+' · '+format(spec['parameters'],'g')+'B')
    category=spec['category'];reasoning=spec['reasoning']
    strengths=spec.get('strengths',{'Everyday':'Conversation, writing, summaries, and everyday questions.','Coding':'Code explanations, programming questions, and drafting snippets.','Reasoning':'Working through multi-step questions with additional thinking time.'}[category])
    limitations=spec.get('limitations','Answer quality varies. Test it with your own tasks before relying on it.')
    if spec['parameters']<1: limitations='Tiny model: useful for experiments, but unreliable for factual questions, conversation recall, and complex instructions.'
    if reasoning: limitations='Thinking takes additional time and memory. Smaller versions can still make reasoning mistakes.'
    if spec['family']=='Gemma' and not vision: limitations+=' MaxModel supports text chat only.'
    if spec['parameters']>=20: limitations+=' Large download; higher-memory hardware recommended.'
    entry=dict(id=spec['id'],name=name,family=spec['family'],series=spec['series'],category=category,
               parameters=spec['parameters'],quantization=quantization,tagline=spec.get('tagline',f"{spec['series']} · {category.lower()} assistant"),
               strengths=strengths,limitations=limitations,preference=spec.get('preference',0),bytes=size,filename=filename,sha256=sha,url=url,
               sourceURL=f'https://huggingface.co/{source}',distributorURL=f'https://huggingface.co/{repo}',license=label,
               licenseID=license_id,licenseURL=license_url,licenseSHA256=license_digest,
               requiresLicenseAcceptance=license_id not in ('apache-2.0','mit'),
               noticeFiles=[dict(filename=n,sha256=hashlib.sha256(d).hexdigest(),sourceURL=u) for n,d,u in docs],
               contextTokens=4096,kvBytesPerToken=kv_bytes,architecture=arch,reasoning=reasoning,
               supportsSystemRole=not spec['id'].startswith('gemma3-'),
               validation='Tested locally' if spec['id'] in TESTED else 'Metadata verified',
               attribution='Built with Llama' if spec['family']=='Llama' else source.split('/')[0],
               metadataCheckedAt=time.strftime('%Y-%m-%d',time.gmtime()),
               knowledge=KNOWLEDGE.get(spec['id']))
    if vision: entry['vision']=vision
    return entry,docs

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--only',nargs='+');parser.add_argument('--cached',action='store_true')
    parser.add_argument('--refresh-weights',action='store_true')
    args=parser.parse_args();CACHE.mkdir(parents=True,exist_ok=True)
    target=ROOT/'Sources/HearthCore/catalog.json';old={m['id']:m for m in json.loads(target.read_text())}
    selected=[s for s in SPECS if not args.only or s['id'] in args.only]
    if args.only and len(selected)!=len(set(args.only)): parser.error('Unknown or duplicate model ID')
    arch_source=read(ARCH_URL).decode();supported=set(re.findall(r'LLM_ARCH_\w+,\s*"([^"]+)"',arch_source))
    results=[];errors=[]
    with concurrent.futures.ThreadPoolExecutor(8) as pool:
        futures={pool.submit(fetch,s,old,args.cached,args.refresh_weights,supported):s for s in selected}
        for future in concurrent.futures.as_completed(futures):
            s=futures[future]
            try:
                result=future.result();results.append(result);m=result[0]
                print(f"OK {m['id']} · {m['license']} · {m['architecture']} · {m['bytes']/1e9:.2f} GB",flush=True)
            except Exception as e: errors.append((s['id'],str(e)));print(f"ERROR {s['id']}: {e}",flush=True)
    if errors: raise SystemExit(f'Catalog unchanged: {len(errors)} entries need review.')
    notice_root=ROOT/'Sources/HearthCore/model-notices';notice_root.mkdir(exist_ok=True)
    for m,docs in results:
        directory=notice_root/m['id'];directory.mkdir(exist_ok=True)
        for name,data,_ in docs: (directory/name).write_bytes(data)
        old[m['id']]=m
    entries=[old[s['id']] for s in SPECS if s['id'] in old]
    temporary=target.with_suffix('.json.tmp');temporary.write_text(json.dumps(entries,indent=2)+'\n');temporary.replace(target)
    print(f'Published {len(entries)} configurations in {len({m["series"] for m in entries})} model groups and {len({m["family"] for m in entries})} families.')
