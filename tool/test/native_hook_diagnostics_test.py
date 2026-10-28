import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from native_hook_diagnostics import collect

class HookDiagnosticTests(unittest.TestCase):
    def test_markers_only_no_environment_or_output_payload(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);folder=root/'.dart_tool/hooks_runner/setup/abc';folder.mkdir(parents=True)
            p=folder/'dependencies_hashes.json'
            p.write_text(json.dumps({'file_system':[{'path':str(root/'core/go.sum'),'hash':1},{'path':str(root/'normal'),'hash':123}], 'environment':[{'key':'TOKEN','value':'fixture-secret'}]}),encoding='utf-8')
            value=collect(root)
            self.assertEqual(value['changed_inputs'][0]['path'],'core/go.sum')
            self.assertEqual(len(value['changed_inputs']),1)
            self.assertNotIn('fixture-secret',json.dumps(value))
            p.write_text('broken',encoding='utf-8')
            self.assertEqual(collect(root)['read_errors'],1)
            p.unlink()
            self.assertEqual(collect(root)['changed_inputs'],[])



class CollectionStateTests(unittest.TestCase):
    def test_missing_empty_complete_partial_and_recovery(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);base=root/'.dart_tool/hooks_runner';base.mkdir(parents=True)
            self.assertEqual(collect(root)['status'],'missing')
            good=base/'dependencies.json'
            good.write_text('{"file_system":[]}',encoding='utf-8')
            self.assertEqual(collect(root)['status'],'complete')
            bad=base/'dependency-bad.json';bad.write_text('{}',encoding='utf-8')
            result=collect(root)
            self.assertEqual(result['status'],'partial');self.assertFalse(result['collected'])
            self.assertEqual(result['files_scanned'],1)
            bad.unlink();self.assertEqual(collect(root)['status'],'complete')
            good.unlink();self.assertEqual(collect(root)['status'],'missing')

    def test_traversal_denied_is_not_empty_success(self):
        from unittest import mock
        import native_hook_diagnostics as module
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'.dart_tool/hooks_runner').mkdir(parents=True)
            with mock.patch.object(module.os,'scandir',side_effect=PermissionError('fixture')):
                result=collect(root)
            self.assertEqual(result['status'],'partial')
            self.assertEqual(result['read_errors'],1)
            self.assertFalse(result['collected'])

if __name__=='__main__':unittest.main()
