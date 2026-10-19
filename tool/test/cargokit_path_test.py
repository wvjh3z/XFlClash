"""PowerShell/CMake UTF-8 protocol fixtures, no app compilation."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
POWERSHELL=os.environ.get('XFL_TEST_POWERSHELL') or shutil.which('powershell') or shutil.which('pwsh')
RESOLVER=ROOT/'plugins/rust_api/cargokit/cmake/resolve_symlinks.ps1'

@unittest.skipUnless(POWERSHELL and shutil.which('cmake'),'PowerShell and CMake required')
class PathTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='cargokit-path-')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.directory=self.root/'中文 ! [路径] & ()'
        self.directory.mkdir()

    def resolve(self,path):
        return subprocess.run([POWERSHELL,'-NoLogo','-NoProfile','-NonInteractive',
            '-ExecutionPolicy','Bypass','-File',str(RESOLVER),str(path)],capture_output=True,timeout=30)

    def test_literal_chinese_path_is_exact_utf8_without_bom(self):
        result=self.resolve(self.directory)
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.decode('utf-8'),self.directory.as_posix())

    def test_missing_path_is_failure_without_machine_output(self):
        result=self.resolve(self.directory/'missing')
        self.assertNotEqual(result.returncode,0);self.assertEqual(result.stdout,b'')

    def test_parent_link_and_relative_target(self):
        link=self.root/'alias'
        if os.name=='nt':
            subprocess.run(['cmd','/d','/c','mklink','/J',str(link),str(self.directory)],check=True,capture_output=True)
        else:link.symlink_to(self.directory.name,target_is_directory=True)
        (self.directory/'child').mkdir()
        result=self.resolve(link/'child')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.decode('utf-8'),(self.directory/'child').as_posix())

    def test_real_cmake_boundary_and_failure_stop(self):
        cmake=(ROOT/'plugins/rust_api/cargokit/cmake/cargokit.cmake').read_text(encoding='utf-8')
        a=cmake.index('    execute_process(');b=cmake.index('\nendif()',a)
        block=cmake[a:b].replace('COMMAND powershell','COMMAND "'+Path(POWERSHELL).as_posix()+'"')
        script=self.root/'probe.cmake'
        prefix='set(CMAKE_CURRENT_LIST_DIR "'+RESOLVER.parent.as_posix()+'")\n'
        for path,valid in ((self.directory,True),(self.directory/'missing',False)):
            script.write_text(prefix+'set(cargokit_cmake_root "'+path.as_posix()+'")\n'+block+
                '\nfile(WRITE "'+(self.root/'result.txt').as_posix()+'" "${cargokit_cmake_root}")\n',encoding='utf-8')
            result=subprocess.run(['cmake','-P',str(script)],capture_output=True,timeout=40)
            self.assertEqual(result.returncode==0,valid,result.stderr)
            if valid:self.assertEqual((self.root/'result.txt').read_text(encoding='utf-8'),path.as_posix())

if __name__=='__main__':
    if not POWERSHELL or not shutil.which('cmake'):
        raise SystemExit('PowerShell and CMake are required')
    unittest.main()
