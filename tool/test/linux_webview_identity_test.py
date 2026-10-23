"""Compile the actual WebKit identity helper; run in private XDG directories."""
from pathlib import Path
import os,shlex,shutil,subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]
class WebKitIdentityTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('pkg-config') and shutil.which('c++'),'Linux native tools required')
    def test_real_webkit_managers_have_distinct_brand_directories(self):
        flags=subprocess.run(['pkg-config','--cflags','--libs','webkit2gtk-4.1'],capture_output=True,text=True)
        if flags.returncode:self.skipTest('WebKitGTK development headers unavailable')
        with tempfile.TemporaryDirectory(prefix='brand-webkit-') as tmp:
            root=Path(tmp);source=root/'main.cc'
            source.write_text('#include "'+str(ROOT/'linux/xboard_webview_identity.h')+'"\n#include <cstdio>\nint main(int argc, char** argv) { gtk_init(&argc,&argv); auto* c=xboard_webview_context();auto* m=webkit_web_context_get_website_data_manager(c);printf("XBOARD_DATA=%s\\nXBOARD_CACHE=%s\\n",webkit_website_data_manager_get_base_data_directory(m),webkit_website_data_manager_get_base_cache_directory(m)); }\n',encoding='utf-8')
            outputs=[]
            for brand in ('omofly','daishu'):
                output=root/brand
                subprocess.run(['c++','-std=c++17','-Wall','-Werror','-DXBOARD_WEBVIEW_APP_ID="com.cloud.app.'+brand+'"',str(source),*shlex.split(flags.stdout),'-o',str(output)],check=True,capture_output=True,timeout=60)
                env={**os.environ,'XDG_DATA_HOME':str(root/'data'),'XDG_CACHE_HOME':str(root/'cache'),'XDG_CONFIG_HOME':str(root/'config'),'HOME':str(root)}
                if not shutil.which('xvfb-run'): raise RuntimeError('xvfb-run required for real GTK context test')
                result=subprocess.run(['xvfb-run','-a',str(output)],env=env,capture_output=True,text=True,timeout=15)
                self.assertEqual(result.returncode,0,result.stderr)
                paths=[line.split('=',1)[1] for line in result.stdout.splitlines() if line.startswith(('XBOARD_DATA=','XBOARD_CACHE='))]
                self.assertEqual(paths,[str(root/'data'/('com.cloud.app.'+brand)/'crisp-webkit'),str(root/'cache'/('com.cloud.app.'+brand)/'crisp-webkit')])
                outputs.append(result.stdout)
            self.assertNotEqual(*outputs)
        source=(ROOT/'linux/CMakeLists.txt').read_text(encoding='utf-8')
        self.assertIn('target_compile_options(desktop_webview_window_plugin PRIVATE',source)
        self.assertIn('xboard_webview_identity.h',source)
if __name__=='__main__': unittest.main()
