"""Run the real branded SQLite/prefs path under Flutter's unit test VM, never integration_test."""
from pathlib import Path
import json,os,sqlite3,subprocess,sys,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]
class BrandDataRuntimeTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform=='linux','Linux real filesystem fixture')
    def test_two_compiled_brands_keep_same_profile_id_and_preferences_separate(self):
        with tempfile.TemporaryDirectory(prefix='brand-data-runtime-') as tmp:
            root=Path(tmp)
            env={**os.environ,'XFLCLASH_IDENTITY_TEST_ROOT':tmp,'XDG_DATA_HOME':str(root/'data'),'XDG_CACHE_HOME':str(root/'cache')}
            for flavor,slug in [('brand_a','omofly'),('brand_b','daishu')]:
                command=[sys.executable,str(ROOT/'tool/flutter_check.py'),'--no-pub',
                    '--dart-define=XB_NATIVE_ID=com.cloud.app.'+slug,'--dart-define=XB_FLAVOR_ID='+flavor,
                    'tool/test/fixtures/brand_data_isolation_runtime.dart','--reporter','expanded']
                result=subprocess.run(command,cwd=ROOT,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=180)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)
            for flavor,slug in [('brand_a','omofly'),('brand_b','daishu')]:
                domain=root/'data'/('com.cloud.app.'+slug)
                with sqlite3.connect('file:'+str(domain/'xboard_index.sqlite')+'?mode=ro',uri=True) as db:
                    self.assertEqual(db.execute('SELECT flavor_id FROM xboard_profile_index_v1').fetchall(),[(flavor,)])
                prefs=json.loads((domain/'shared_preferences.json').read_text(encoding='utf-8'))
                self.assertEqual(prefs['flutter.brand-fixture'],'com.cloud.app.'+slug)
            self.assertEqual((root/'legacy/database.sqlite').read_text(encoding='utf-8'),'legacy sentinel')
if __name__=='__main__':unittest.main()
