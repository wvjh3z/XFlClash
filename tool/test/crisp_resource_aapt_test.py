"""Opt-in real AAPT resource-table tests. No application/Dart/native compilation.
Set CRISP_SDK_AAR to the official pinned archive; optional CRISP_OLD_APK is a
known broken package. Uses the existing Android SDK, never downloads one.
"""
from pathlib import Path
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from crisp_resource_inventory import inventory as aar_inventory
from check_android_release_contract import CRISP_CONTRACT,find_aapt,verify_crisp_resources

@unittest.skipUnless(os.environ.get('CRISP_SDK_AAR'),'Requires explicit official AAR and Android SDK')
class ResourceTableTest(unittest.TestCase):
    def test_official_keep_rules_and_inventory(self):
        aar=Path(os.environ['CRISP_SDK_AAR'])
        self.assertEqual(hashlib.sha256(aar.read_bytes()).hexdigest(),CRISP_CONTRACT['aar_sha256'])
        with zipfile.ZipFile(aar) as z:
            keep=ET.fromstring(z.read('res/raw/crisp_sdk_keep.xml')).get('{http://schemas.android.com/tools}keep')
            self.assertEqual(set(keep.split(',')),{'@bool/crisp_*','@color/crisp_*','@drawable/crisp_*','@raw/crisp_*','@string/crisp_*','@style/Theme_Crisp_*'})
            inventory=[]
            for line in z.read('R.txt').decode().splitlines():
                f=line.split()
                if len(f)!=4 or f[0]!='int' or f[2]=='crisp_sdk_keep':continue
                if (f[1] in ('bool','color','drawable','raw','string') and f[2].startswith('crisp_')) or (f[1]=='style' and f[2].startswith('Theme_Crisp_')):
                    inventory.append(f[1]+'/'+f[2])
            self.assertEqual(sorted(inventory),sorted(CRISP_CONTRACT['resources']))
            self.assertEqual(aar_inventory(aar, CRISP_CONTRACT['aar_sha256']), CRISP_CONTRACT['resources'])

    def test_both_brands_real_table_and_missing_boolean(self):
        aapt=Path(find_aapt());aapt2=aapt.with_name('aapt2')
        sdk=Path(os.environ.get('ANDROID_HOME') or os.environ['ANDROID_SDK_ROOT'])
        android=next(sdk.glob('platforms/android-37*/android.jar'))
        with tempfile.TemporaryDirectory(prefix='crisp-resource-table-') as tmp:
            root=Path(tmp);res=root/'res';(res/'values').mkdir(parents=True);(res/'raw').mkdir()
            values=ET.Element('resources')
            for resource,name in CRISP_CONTRACT['resources'].items():
                kind=resource.split('/')[0]
                if kind=='raw':(res/'raw'/f'{name}.bin').write_bytes(b'fixture');continue
                if kind=='style':ET.SubElement(values,'style',{'name':name,'parent':''});continue
                if kind=='drawable':ET.SubElement(values,'item',{'type':kind,'name':name}).text='@android:color/transparent';continue
                ET.SubElement(values,kind,{'name':name}).text={'bool':'false','color':'#FF123456','string':'fixture'}[kind]
            def run(args):return subprocess.check_output(list(map(str,args)),stderr=subprocess.STDOUT,timeout=60).decode()
            for package in ['com.cloud.app.omofly','com.cloud.app.daishu']:
                for mode in ['good','missing_bool','underscores','mixed','missing_original','null_bool','empty_bool','null_style','null_and_locale','zero_colors','aliases','chain_false','chain_null','chain_cycle','cross_cycle','cross_null','fallback_source','fallback_target','bad_night_cycle','bad_night_null','bad_fallback_null','bad_fallback_cycle']:
                    tree=ET.fromstring(ET.tostring(values))
                    locale=res/'values-ar/rtl.xml'
                    locale.unlink(missing_ok=True)
                    night=res/'values-night/cross.xml'
                    night.unlink(missing_ok=True)
                    if mode in ['cross_cycle','cross_null','fallback_source','fallback_target','bad_night_cycle','bad_night_null','bad_fallback_null','bad_fallback_cycle']:
                        default_a='@bool/xb_cross' if mode in ['fallback_source','bad_fallback_cycle'] else 'false'
                        default_b='@bool/crisp_is_rtl' if mode=='cross_cycle' else '@null' if mode in ['cross_null','bad_fallback_null'] else 'false'
                        night_a=None if mode in ['fallback_source','bad_fallback_cycle'] else '@bool/xb_cross'
                        night_b=None if mode in ['fallback_target','bad_fallback_null'] else '@bool/crisp_is_rtl' if mode in ['bad_night_cycle','bad_fallback_cycle'] else '@null' if mode=='bad_night_null' else 'true'
                        tree.find("bool[@name='crisp_is_rtl']").text=default_a
                        ET.SubElement(tree,'bool',{'name':'xb_cross'}).text=default_b
                        alternative=ET.Element('resources')
                        if night_a is not None:ET.SubElement(alternative,'bool',{'name':'crisp_is_rtl'}).text=night_a
                        if night_b is not None:ET.SubElement(alternative,'bool',{'name':'xb_cross'}).text=night_b
                        night.parent.mkdir(exist_ok=True)
                        ET.ElementTree(alternative).write(night,encoding='utf-8')
                    elif mode in ['chain_false','chain_null','chain_cycle']:
                        tree.find("bool[@name='crisp_is_rtl']").text='@bool/xb_middle'
                        ET.SubElement(tree,'bool',{'name':'xb_middle'}).text='@bool/xb_leaf'
                        ET.SubElement(tree,'bool',{'name':'xb_leaf'}).text=('false' if mode=='chain_false' else '@null' if mode=='chain_null' else '@bool/xb_middle')
                    elif mode in ['null_bool','null_and_locale','empty_bool']:
                        tree.find("bool[@name='crisp_is_rtl']").text='@empty' if mode=='empty_bool' else '@null'
                        if mode=='null_and_locale':
                            locale.parent.mkdir(exist_ok=True)
                            locale.write_text('<resources><bool name="crisp_is_rtl">true</bool></resources>')
                    elif mode=='null_style':
                        target=tree.find("style[@name='Theme.Crisp.SDK.Dialog.Red']")
                        tree.remove(target)
                        ET.SubElement(tree,'item',{'type':'style','name':'Theme.Crisp.SDK.Dialog.Red'}).text='@null'
                    elif mode in ['zero_colors','aliases']:
                        for color in tree.findall('color'):
                            color.text='#00000000' if mode=='zero_colors' else '@android:color/transparent'
                    elif mode=='missing_bool':tree.remove(tree.find("bool[@name='crisp_is_rtl']"))
                    elif mode=='missing_original':tree.remove(tree.find("string[@name='crisp_sdk_audio_speed_1.5']"))
                    elif mode in ['underscores','mixed']:
                        for element in tree:
                            name=element.get('name','')
                            if '.' in name:element.set('name',name.replace('.','_') if mode=='underscores' else name.replace('.','_',1))
                    ET.ElementTree(tree).write(res/'values/resources.xml',encoding='utf-8')
                    (root/'AndroidManifest.xml').write_text(f'<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{package}"><application /></manifest>')
                    run([aapt2,'compile','--dir',res,'-o',root/'compiled.zip'])
                    table=root/'resources.ap_'
                    run([aapt2,'link','-I',android,'--manifest',root/'AndroidManifest.xml','-o',table,root/'compiled.zip'])
                    dump=run([aapt,'dump','resources',table])
                    if mode not in ['good','zero_colors','aliases','chain_false','cross_cycle','cross_null','fallback_source','fallback_target']:
                        with self.assertRaises(ValueError):verify_crisp_resources(dump,package)
                    else:self.assertEqual(verify_crisp_resources(dump,package),1295)

    @unittest.skipUnless(os.environ.get('CRISP_CURRENT_APK'),'Optional existing build40 positive control')
    def test_actual_build40_passes_exact_names(self):
        dump=subprocess.check_output([str(find_aapt()),'dump','resources',os.environ['CRISP_CURRENT_APK']],timeout=60).decode()
        self.assertEqual(verify_crisp_resources(dump,'com.cloud.app.omofly'),1295)

    @unittest.skipUnless(os.environ.get('CRISP_OLD_APK'),'Optional broken APK negative control')
    def test_actual_build39_rejected(self):
        dump=subprocess.check_output([str(find_aapt()),'dump','resources',os.environ['CRISP_OLD_APK']],timeout=60).decode()
        with self.assertRaisesRegex(ValueError,'bool/crisp_is_rtl'):
            verify_crisp_resources(dump,'com.cloud.app.omofly')

if __name__=='__main__':unittest.main()
