"""Compile the actual WebKit identity helper; run in private XDG directories."""
from pathlib import Path
import os,shlex,shutil,subprocess,tempfile,unittest
from tool.test.webkit_probe_support import owned, wait_ready, wait_complete
ROOT=Path(__file__).resolve().parents[2]
class WebKitIdentityTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('pkg-config') and shutil.which('c++'),'Linux native tools required')
    def test_real_webkit_managers_have_distinct_brand_directories(self):
        flags=subprocess.run(['pkg-config','--cflags','--libs','webkit2gtk-4.1'],capture_output=True,text=True)
        if flags.returncode:self.skipTest('WebKitGTK development headers unavailable')
        with tempfile.TemporaryDirectory(prefix='brand-webkit-') as tmp:
            root=Path(tmp);source=root/'main.cc'
            source.write_text('#include "'+str(ROOT/'linux/xboard_webview_identity.h')+'"\n#include <cstdio>\nint main(int argc, char** argv) { setbuf(stdout,nullptr); puts("PHASE=gtk_init"); gtk_init(&argc,&argv); puts("PHASE=webkit_context"); auto* c=xboard_webview_context(); puts("PHASE=manager");auto* m=webkit_web_context_get_website_data_manager(c);printf("XBOARD_DATA=%s\\nXBOARD_CACHE=%s\\n",webkit_website_data_manager_get_base_data_directory(m),webkit_website_data_manager_get_base_cache_directory(m)); puts("PHASE=complete"); return 0; }\n',encoding='utf-8')
            outputs=[]
            for brand in ('omofly','daishu'):
                output=root/brand
                compiled=subprocess.run(['c++','-std=c++17','-Wall','-Werror','-DXBOARD_WEBVIEW_APP_ID="com.cloud.app.'+brand+'"',str(source),*shlex.split(flags.stdout),'-o',str(output)],capture_output=True,text=True,timeout=60)
                self.assertEqual(compiled.returncode,0,compiled.stdout+compiled.stderr)
                env={**os.environ,'XDG_DATA_HOME':str(root/'data'),'XDG_CACHE_HOME':str(root/'cache'),'XDG_CONFIG_HOME':str(root/'config'),'HOME':str(root),
                     'GDK_BACKEND':'x11','NO_AT_BRIDGE':'1'}
                # Do not inherit a runner's unrelated desktop/session bus.
                for key in ('DISPLAY','WAYLAND_DISPLAY','DBUS_SESSION_BUS_ADDRESS','DBUS_STARTER_ADDRESS','DBUS_STARTER_BUS_TYPE'):
                    env.pop(key,None)
                runtime=root/('runtime-'+brand);runtime.mkdir(mode=0o700)
                env['XDG_RUNTIME_DIR']=str(runtime)
                for tool in ('Xvfb','dbus-run-session'):
                    if not shutil.which(tool):raise RuntimeError(tool+' required for real GTK context test')
                display=root/('display-'+brand)
                with display.open('w+b') as ready_file:
                    with owned(['Xvfb','-displayfd',str(ready_file.fileno()),'-screen','0','800x600x24','-nolisten','tcp'],root,'xvfb-'+brand,env=env,pass_fds=(ready_file.fileno(),)) as (server,_,__):
                        number=wait_ready(server,lambda: display.read_text().strip(),phase='xvfb',timeout=30)
                        self.assertTrue(number.isdecimal(), 'invalid Xvfb readiness response')
                        env['DISPLAY']=':'+number
                        with owned(['dbus-run-session','--',str(output)],root,'webkit-'+brand,env=env) as (probe,out,err):
                            stdout=wait_complete(probe,out)
                paths=[line.split('=',1)[1] for line in stdout.splitlines() if line.startswith(('XBOARD_DATA=','XBOARD_CACHE='))]
                self.assertEqual(paths,[str(root/'data'/('com.cloud.app.'+brand)/'crisp-webkit'),str(root/'cache'/('com.cloud.app.'+brand)/'crisp-webkit')])
                outputs.append(stdout)
            self.assertNotEqual(*outputs)
        source=(ROOT/'linux/CMakeLists.txt').read_text(encoding='utf-8')
        self.assertIn('target_compile_options(desktop_webview_window_plugin PRIVATE',source)
        self.assertIn('xboard_webview_identity.h',source)
if __name__=='__main__': unittest.main()
