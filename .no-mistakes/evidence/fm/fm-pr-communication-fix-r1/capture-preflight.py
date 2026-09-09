from pathlib import Path
import subprocess, os, json, hashlib
root=Path.cwd()
evidence=Path('/home/rich/.no-mistakes/evidence/01M1ZWGPMKC8FVWJ0XHPHYGNNG')
scratch=root/'.test-tmp'/'capture'
scratch.mkdir(exist_ok=True)
(scratch/'bin').mkdir(exist_ok=True)
branch='fm/preflight'
fixture=scratch/'repo'
fixture.mkdir()
subprocess.run(['git','init','-q','-b',branch,str(fixture)],check=True)
env=dict(os.environ, PATH=str(scratch/'bin')+':'+os.environ['PATH'], GITHUB_STEP_SUMMARY='', NODE_NO_WARNINGS='1')
# Only the forge transport is simulated. No forge or pipeline writes occur.
stub=scratch/'bin'/'gh-axi'
stub.write_text('''#!/usr/bin/env python3
import pathlib,base64,sys,json
p=pathlib.Path(__file__).parents[1]
with (p/'calls.jsonl').open('a') as f: f.write(json.dumps(sys.argv[1:])+'\\n')
assert sys.argv[1:4]==['api','GET','/repos/o/r/pulls']
print('api_response:\\n  body: '+base64.b64encode((p/'pulls.json').read_bytes()).decode()+'\\n  truncated: false')
''')
stub.chmod(0o755)
canonical='''## CEO overview

- **What is changing:** Members can see the status of their submitted requests.
- **Why it matters:** It reduces support messages asking for updates.
- **Customer or business impact:** Members get clearer communication and the team saves time.
- **Risk and rollout:** Low risk. Release through staging and confirm the main request flow.

## What changed technically

Render request status in the existing member page.

## Validation

- **Checks passed:** Unit tests and type check.
- **Checks not run:** End-to-end test was not run locally.
- **Evidence and limitations:** Tested with a representative request.

## Module-boundary decision

Current module retained: request status rendering belongs with the existing member request page module.

## Decision needed

No decision required.
'''
# Reuse the existing executable test's synthetic pipeline fixture verbatim.
test=(root/'tests/pr-communication.test.sh').read_text()
pipeline=test.split("pipeline_section() {\n  cat <<'EOF'\n",1)[1].split('\nEOF\n}',1)[0]+'\n'
intent=scratch/'intent.md'
transcript=['Public delivery preflight replay at af80dc8f5ff476f41060d5df84d8cfdf22e0eb40',
'Only gh-axi transport is controlled; all preflight/assessor code executes normally.',
'Pipeline data is the existing synthetic test fixture, never published. Hosted Actions were not run.\n']
previous=root/'scripts'/'check-pr-delivery.test-before.ts'
previous.write_bytes(subprocess.check_output(['git','show','HEAD^:scripts/check-pr-delivery.ts']))
def run(label,args,expected,body=None):
    e=env.copy()
    if body is not None: e.update(PR_TITLE='Show members their request status',PR_BODY=body)
    p=subprocess.run(args,cwd=fixture,env=e,capture_output=True,text=True)
    transcript.extend(['\nCASE: '+label,'$ '+' '.join(str(x).replace(str(root)+'/','') for x in args),f'exit={p.returncode}; stdout_bytes={len(p.stdout.encode())}', 'stdout:\n'+p.stdout, 'stderr:\n'+p.stderr])
    assert p.returncode==expected,(label,p.returncode,p.stderr)
    return p
args=[str(root/'bin/fm-nm-pr-preflight.sh'),'--intent-file',str(intent),'--repo','o/r','--head','o:'+branch]
def forge(body):
    pulls=[] if body is None else [dict(title='Show members their request status',state='open',body=body,base={'repo':{'full_name':'o/r'}},head={'ref':branch,'sha':'0'*40,'repo':{'owner':{'login':'o'}}})]
    (scratch/'pulls.json').write_text(json.dumps(pulls))
def hosted(label,body,expected):
    return run(label,['node','--experimental-strip-types',str(root/'scripts/check-pr-communication.ts')],expected,body)
try:
    intent.write_text(canonical); forge(None)
    p=run('Fresh canonical intent',args,0); assert p.stdout==canonical
    (evidence/'validated-intent.md').write_text(p.stdout)
    generated='## Intent\n\n'+canonical+pipeline
    (evidence/'generated-body-fixture.md').write_text(generated)
    hosted('Canonical generated body, original hosted interface',generated,0)
    run('Canonical generated body, Firstmate hosted interface',['node','--experimental-strip-types',str(root/'scripts/check-firstmate-ceo-overview.ts')],0,generated)
    for target in ['intent','live']:
        for label in ['What is changing','Checks passed']:
            bad=canonical.replace('- **'+label+':**',label+': pending\n- **'+label+':**',1)
            intent.write_text(bad if target=='intent' else canonical)
            body=bad if target=='intent' else bad+pipeline
            forge(None if target=='intent' else body)
            (evidence/(target+'-'+label.lower().replace(' ','-')+'-r16.md')).write_text(body)
            hosted('R16 '+target+' '+label+' unchanged input',body,1)
            before=['node','--experimental-strip-types',str(previous)]+args[1:]
            run('Before R16 fix: '+target+' '+label,before,0)
            p=run('After R16 fix: '+target+' '+label,args,2); assert not p.stdout
    intent.write_text(canonical)
    forge('## Summary\nLegacy publisher body.\n'+pipeline)
    p=run('Stale live body cannot be hidden by complete local intent',args,2); assert not p.stdout
    forge(canonical+pipeline)
    p=run('Owner-reconciled live body, unchanged intent',args,0); assert p.stdout==canonical
    forge((canonical+pipeline).replace('0'*40,'1'*40))
    p=run('Stale live attestation head',args,2); assert not p.stdout
    forge(None)
    for value in ['***','[unused]: https://example.invalid']:
        intent.write_text(canonical.replace('Render request status in the existing member page.',value))
        run('R15 deferred completeness case: '+value,args,0)
    transcript.append('\nR15 remains reproducible and was not changed, per the separate recorded decision.\n')
finally:
    previous.unlink()
    (evidence/'public-preflight-replay.txt').write_text('\n'.join(transcript))
print('Saved public-preflight-replay.txt and exact Markdown inputs; before/after assertions passed.')
