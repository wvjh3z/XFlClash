"""Real Go, empty cache and loopback proxy; downloads only, never builds."""
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import unittest
import zipfile

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import prepare_go_dependencies as production
from pub_get_retry import execute

class NativeGoTests(unittest.TestCase):
    def test_empty_cache_transient_failure_recovers_without_input_changes(self):
        go=shutil.which('go')
        self.assertIsNotNone(go,'Go must be installed before this native preflight')
        module='example.invalid/fixture';version='v1.0.0'
        mod=b'module example.invalid/fixture\n\ngo 1.20\n'
        archive=io.BytesIO()
        with zipfile.ZipFile(archive,'w') as z:
            z.writestr(module+'@'+version+'/go.mod',mod)
            z.writestr(module+'@'+version+'/fixture.go',b'package fixture\n')
        state={'fail_zip':False,'failures':0,'zip_reads':0}
        bodies={'.mod':mod,'.info':b'{"Version":"v1.0.0","Time":"2020-01-01T00:00:00Z"}', '.zip':archive.getvalue()}
        class Proxy(BaseHTTPRequestHandler):
            def log_message(self,*args):pass
            def do_GET(self):
                suffix=next((s for s in bodies if self.path==f'/{module}/@v/{version}'+s),None)
                if suffix is None:self.send_error(404);return
                if suffix=='.zip':
                    state['zip_reads']+=1
                    if state['fail_zip']:
                        state['fail_zip']=False;state['failures']+=1
                        self.send_error(503);return
                body=bodies[suffix];self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
        server=ThreadingHTTPServer(('127.0.0.1',0),Proxy)
        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
        try:
            with tempfile.TemporaryDirectory(prefix='go-deps-中文 space-') as tmp:
                root=Path(tmp)/'source';core=root/'core';(core/'Clash.Meta').mkdir(parents=True)
                (core/'go.mod').write_text('module fixture\n\ngo 1.20\n\nrequire '+module+' '+version+'\nrequire local.invalid/meta v0.0.0\nreplace local.invalid/meta => ./Clash.Meta\n',encoding='utf-8')
                (core/'Clash.Meta/go.mod').write_text('module local.invalid/meta\n\ngo 1.20\n',encoding='utf-8')
                # Disable public sumdb ONLY for this private loopback module.
                env={**os.environ,'GOMODCACHE':str(Path(tmp)/'warm'),'GOPROXY':f'http://127.0.0.1:{server.server_port}','GOSUMDB':'off','GOWORK':'off','GOTOOLCHAIN':'local','GONOPROXY':'','GOFLAGS':''}
                prime=subprocess.run([go,'mod','download','all'],cwd=core,env=env,capture_output=True,text=True,timeout=60)
                self.assertEqual(prime.returncode,0,prime.stderr)
                env['GOMODCACHE']=str(Path(tmp)/'empty-cache');state['fail_zip']=True
                def run(*args,**kwargs):
                    return execute(*args,**{**kwargs,'delays':(0,0),'emit':lambda _:None})
                production.prepare(root,runner=run,environment=env)
                report=json.loads((root/'build/dependency-retries/go.json').read_text(encoding='utf-8'))
                self.assertTrue(report['passed']);self.assertEqual(report['changed_inputs'],[])
                self.assertEqual(state['failures'],1)
                self.assertEqual(len(report['retry']['attempts']),2)
                self.assertTrue((Path(tmp)/'empty-cache'/ (module+'@'+version)/'fixture.go').is_file())
                # Real Go may create sums: it must create them only in the copy.
                original_sum=(core/'go.sum').read_text(encoding='utf-8')
                (core/'go.sum').unlink()
                production.prepare(root,runner=run,environment=env)
                self.assertFalse((core/'go.sum').exists())
                evidence=json.loads((root/'build/dependency-retries/go.json').read_text(encoding='utf-8'))
                self.assertIn('go.sum',evidence['isolated_changed_inputs'])
                # A real checksum mismatch is permanent, not a retryable download.
                (core/'go.sum').write_text(original_sum.replace('h1:', 'h1:bad'),encoding='utf-8')
                before=production.snapshot(core)
                with self.assertRaises(RuntimeError):production.prepare(root,runner=run,environment=env)
                self.assertEqual(production.snapshot(core),before)
                evidence=json.loads((root/'build/dependency-retries/go.json').read_text(encoding='utf-8'))
                self.assertFalse(evidence['passed'])
                self.assertEqual(len(evidence['retry']['attempts']),1)

        finally:
            server.shutdown();server.server_close();thread.join(timeout=5)

if __name__=='__main__':unittest.main()
