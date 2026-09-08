#!/usr/bin/env bash
# Offline public-protocol tests. The guest identity/paths are injected only by
# this test driver; production has no environment switch that bypasses them.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
python3 - "$root" <<'PY'
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    guest = base / 'guest'
    bindir = guest / '.local/bin'
    state = guest / '.local/state/firstmate/astra'
    profile = guest / '.config/chromium-astra'
    vendor = guest / '.local/share/codex/vendor'
    marker = base / 'run/ready'
    manifest = guest / '.local/share/codex/readiness.json'
    for directory in (bindir, state, profile, vendor / 'cua_repl/scripts',
                      vendor / 'node_repl', vendor / 'cua_node/bin',
                      vendor / 'cua_node/lib/node_modules', marker.parent):
        directory.mkdir(parents=True, exist_ok=True)
        directory.chmod(0o700)
    for path in (bindir / 'codex-code-mode-host', vendor / 'cua_repl/scripts/launch.mjs',
                 vendor / 'cua_node/bin/node', guest / 'chrome'):
        path.touch()
        path.chmod(0o755)
    manifest.parent.chmod(0o700)
    shutil.copy(root / 'bin/fm-astra-guest.py', bindir)
    shutil.copy(root / 'bin/fm-astra-ready.py', bindir / 'ready-source.py')
    shutil.copy(root / 'bin/fm-codex-client.py', bindir / 'client-source.py')
    driver = '''import importlib.util, os, sys
from pathlib import Path
base=Path(__file__).resolve().parent
def load(name,path):
 spec=importlib.util.spec_from_file_location(name,path)
 module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module
c=load('test_client',base/'client-source.py')
c.HOME=base.parent.parent;c.STATE=c.HOME/'.local/state/firstmate/astra'
c.PROFILE=c.HOME/'.config/chromium-astra';c.VENDOR=c.HOME/'.local/share/codex/vendor'
c.CODEX=base/'codex';c.MARKER=c.HOME.parent/'run/ready';c.TIMEOUT=0.6
c.identity=lambda:None
original=c.components
c.components=lambda:dict(original(),chrome=c.HOME/'chrome')
HOME=c.HOME
'''
    # ready-source imports this source file, then the readiness driver sets its
    # client to the same test instance before entering its public main().
    shutil.copy(root / 'bin/fm-codex-client.py', bindir / 'fm-codex-client.py')
    adapter = bindir / 'fm-codex-client'
    adapter.write_text('#!/usr/bin/env python3\n' + driver + '''
if __name__=='__main__':
 sys.stdout.reconfigure(encoding='utf-8');sys.stderr.reconfigure(encoding='utf-8')
 raise SystemExit(c.main())
''')
    adapter.chmod(0o755)
    ready = bindir / 'ready-driver'
    ready.write_text('#!/usr/bin/env python3\n' + driver + '''
r=load('test_ready',base/'ready-source.py');r.client=c
r.MANIFEST=c.HOME/'.local/share/codex/readiness.json';r.ADAPTER=base/'fm-codex-client'
raise SystemExit(r.main())
''')
    ready.chmod(0o755)
    codex = bindir / 'codex'
    codex.write_text('''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
sys.stdin.reconfigure(encoding='utf-8');sys.stdout.reconfigure(encoding='utf-8')
mode=os.environ.get('CASE','ok')
if sys.argv[1:] == ['--version']:
 print('codex-cli 0.153.4');raise SystemExit(0)
if sys.argv[1:] == ['login','status']:
 print('test-password-DO-NOT-LEAK',file=sys.stderr)
 raise SystemExit(1 if mode=='missing_auth' else 0)
assert 'app-server' in sys.argv
print('test-password-DO-NOT-LEAK',file=sys.stderr,flush=True)
def emit(d):print(json.dumps(d,ensure_ascii=False),flush=True)
def start_call():
 code=codes[index]
 Path(os.environ['TRACE']).write_text(code,encoding='utf-8')
 emit({'method':'item/started','params':{'item':{'id':'call'+str(index),'type':'mcpToolCall','server':'cua_repl','tool':'js','arguments':{'code':code+' extra' if mode=='unapproved' else code}}}})
 if mode=='no_approval':
  emit({'method':'item/completed','params':{'item':{'id':'call'+str(index),'type':'mcpToolCall','status':'completed','result':{}}}})
 emit({'id':900,'method':'mcpServer/elicitation/request','params':{'serverName':'cua_repl','threadId':'thread','mode':'form','message':'Allow the cua_repl MCP server to run tool "js"?','requestedSchema':{'type':'object','properties':{}}}})
for line in sys.stdin:
 d=json.loads(line);method=d.get('method')
 if method=='initialize':emit({'id':d['id'],'result':{}})
 if method=='thread/start':emit({'id':d['id'],'result':{'thread':{'id':'thread'},'model':'wrong' if mode=='model' else 'gpt-6-astra','approvalPolicy':'on-request'}})
 if method=='turn/start':
  codes=json.loads(d['params']['input'][0]['text'].split('\\n',1)[1]);index=0
  emit({'id':d['id'],'result':{}})
  if mode=='timeout':time.sleep(10)
  start_call()
 if d.get('id')==900 and 'method' not in d:
  assert d['result']=={'action':'accept','content':{}}
  emit({'method':'item/completed','params':{'item':{'id':'call'+str(index),'type':'mcpToolCall','status':'failed' if mode=='tool' else 'completed','result':{'content':[{'type':'image','data':'fake-image'}] if index==1 and mode!='no_image' else []}}}})
  index+=1
  if index<2:
   start_call();continue
  emit({'method':'item/completed','params':{'item':{'type':'agentMessage','text':'test-password-DO-NOT-LEAK'}}})
  emit({'method':'turn/completed','params':{'turn':{'status':'completed'}}})
''')
    codex.chmod(0o755)
    trace = base / 'trace'
    request_id = str(uuid.uuid4())
    env = dict(os.environ, DISPLAY=':1', FM_ASTRA_REQUEST_ID=request_id,
               FM_ASTRA_SESSION_DIR=str(state), FM_ASTRA_BROWSER_PROFILE=str(profile),
               FM_ASTRA_DESKTOP_OWNER='agent', TRACE=str(trace), LC_ALL='C', PYTHONUTF8='0')
    def call(payload=None, case='ok', raw=None):
        trace.unlink(missing_ok=True)
        value = {'protocol': 1, 'request_id': request_id, 'operation': 'smoke'}
        value.update(payload or {})
        result = subprocess.run([str(adapter)], input=raw if raw is not None else
                                (json.dumps(value, ensure_ascii=False)+'\n').encode('utf-8'),
                                capture_output=True, env=dict(env, CASE=case),
                                start_new_session=True, timeout=8)
        assert len(result.stdout.splitlines()) == 1, result.stdout
        parsed = json.loads(result.stdout.decode('utf-8'))
        if case == 'missing_auth' or parsed.get('error') == 'confirmation_required':
            assert not trace.exists(), 'refused request reached a model turn'
        assert b'test-password-DO-NOT-LEAK' not in result.stdout + result.stderr
        if result.returncode:
            assert parsed['ok'] is False and result.stderr.startswith(b'fm-codex-client: ')
        else:
            assert parsed['ok'] is True and result.stderr == b''
        return parsed
    assert call()['screenshot_observed'] is True
    for case, error in (('missing_auth','missing_auth'), ('model','unsupported_model'),
                        ('unapproved','unapproved_tool_call'), ('timeout','timeout'),
                        ('tool','desktop_tool_failed'), ('no_image','screenshot_not_observed'),
                        ('no_approval','approval_not_observed')):
        assert call(case=case)['error'] == error, case
    for raw in (b'{}\n{}\n', b'not-json\n', b'[]\n', b'\xff\n', b'{}',
                b'{"protocol":1,"protocol":1}\n', b'{}\n\n', b'x'*65537):
        assert call(raw=raw)['error'] == 'malformed_input', raw[:30]
    assert call({'model':'gpt-5'})['error']=='unsupported_model'
    assert call({'prompt':'untrusted free-form request'})['error']=='unsupported_prompt_use_actions'
    actions=[{'type':'type_text','text':'Tiếng Việt 😀 " \\ $() test-password-DO-NOT-LEAK'}]
    assert call({'operation':'actions','actions':actions})['error']=='confirmation_required'
    marker.write_text(json.dumps({'schema':1,'state':'ready','model':'gpt-6-astra',
                                 'adapter_sha256':hashlib.sha256(adapter.read_bytes()).hexdigest()}))
    marker.chmod(0o600)
    result=call({'operation':'actions','actions':actions,'confirm_actions':True})
    assert result.get('actions_completed')==1, result
    assert actions[0]['text'] in json.loads(trace.read_text().split('type_text(',1)[1].split(');',1)[0])['text']
    assert call({'operation':'actions','actions':[{'type':'shell','command':'unsafe'}],'confirm_actions':True})['error']=='malformed_action'
    missing=vendor/'node_repl';missing.rmdir()
    assert call()['error']=='missing_component_node_repl'
    missing.mkdir()
    spec=importlib.util.spec_from_file_location('helper', root/'bin/fm-astra-guest.py')
    helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
    def initial():
        return {'schema':1,'vm':{'id':'fixture','guest_user':'astra'},
                'reachability':{'endpoint':'guest.private','transport':'ssh','auth_method':'guest-key','authenticated':True,'public':False},
                'desktop':{'display':':1','viewer':'private-vnc','browser_profile':str(profile)},
                'lifecycle':{'owner':'infra'},'readiness':{'marker':str(marker),'state':'pending','astra_identifier':'gpt-6-astra'},
                'components':{'cua_repl':str(vendor/'cua_repl'),'node_repl':str(vendor/'node_repl'),'client_adapter':str(adapter)},
                'credential_status':'pending'}
    def publish(operation='refresh',case='ok'):
        r=subprocess.run([str(ready),operation],capture_output=True,env=dict(env,CASE=case),timeout=8)
        assert b'test-password-DO-NOT-LEAK' not in r.stdout+r.stderr
        return r,json.loads(r.stdout)
    manifest.write_text(json.dumps(initial()))
    manifest.chmod(0o600)
    r,value=publish();assert r.returncode==0 and value['state']=='ready', (r.stdout,r.stderr)
    assert marker.stat().st_mode & 0o777 == 0o600
    assert marker.stat().st_uid == os.geteuid()
    assert json.loads(manifest.read_text())['credential_status']=='available'
    assert json.loads(marker.read_text())['model']=='gpt-6-astra'
    adapter.chmod(0o644)
    r,value=publish();assert value['condition']=='unsafe_or_nonexecutable_adapter' and not marker.exists()
    adapter.chmod(0o755)
    for case in ('missing_auth','model','tool','no_image'):
        r,value=publish(case=case)
        assert r.returncode==3 and value['state']=='pending' and not marker.exists(), (case,r.stdout,r.stderr)
        assert json.loads(manifest.read_text())['readiness']['state']=='pending'
    r,value=publish('remove');assert r.returncode==0 and not marker.exists()
    (state/'handoff.json').write_text('{"mode":"human","generation":1}')
    r,value=publish();assert value['condition']=='human_takeover_active' and not marker.exists()
    (state/'handoff.json').unlink()
    doc=initial();doc['components']['extra']=str(base/'missing')
    manifest.write_text(json.dumps(doc))
    r,value=publish();assert value['condition']=='published_component_missing_extra' and not marker.exists()
    manifest.write_text(json.dumps(initial()))
    marker.parent.rmdir()
    r,value=publish();assert value['condition']=='missing_runtime_directory' and not marker.exists()
    assert json.loads(manifest.read_text())['readiness']['state']=='pending'
    # Real process-group cleanup on successful parent exit, not just timeouts.
    pidfile=base/'child.pid'
    sleeper=base/'sleeper.py'
    sleeper.write_text('import subprocess,sys\np=subprocess.Popen(["sleep","30"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)\nopen(sys.argv[1],"w").write(str(p.pid))\n')
    with helper.client_process([sys.executable,str(sleeper),str(pidfile)],dict(os.environ)) as process:
        process.communicate(timeout=3)
    pid=int(pidfile.read_text())
    import time
    for _ in range(30):
        status=Path('/proc')/str(pid)/'stat'
        if not status.exists() or status.read_text().split()[2]=='Z':break
        time.sleep(0.02)
    else:raise AssertionError('successful client left descendant running')
print('pass: JSON-line, Unicode, refusals, stderr secrecy, approval binding, readiness and process cleanup')
PY
