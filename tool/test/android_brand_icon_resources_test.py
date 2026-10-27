"""Resource contracts for adaptive icon scaling and splash isolation; no APK build."""
from pathlib import Path
import struct
import math
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from icon_png_reader import rgba
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / 'android/app/src/brand_b/res'
A = '{http://schemas.android.com/apk/res/android}'


def verify_foreground(root):
    assert root.tag == 'layer-list'
    items = root.findall('item')
    assert len(items) == 2
    for item in items:
        assert not any(A + k in item.attrib for k in ('width', 'height', 'gravity', 'left', 'right', 'top', 'bottom'))
    vector = items[0].find('vector')
    assert vector is not None
    assert vector.get(A+'viewportWidth') == vector.get(A+'viewportHeight') == '108'
    assert vector.get(A+'width') == vector.get(A+'height') == '108dp'
    path = vector.find('path')
    assert path.get(A+'fillColor') == '#FFFFFF'
    assert path.get(A+'pathData') == 'M54,19 a35,35 0,1 0,0,70 a35,35 0,1 0,0,-70'
    bitmap = items[1].find('bitmap')
    assert bitmap.get(A+'src') == '@mipmap/ic_fg'
    assert bitmap.get(A+'gravity') == 'fill'


class IconResourcesTest(unittest.TestCase):
    def test_foreground_scales_instead_of_using_fixed_layer_dimensions(self):
        verify_foreground(ET.parse(RES/'drawable/ic_launcher_foreground.xml').getroot())
        for density,scale in [('mdpi',1),('hdpi',1.5),('xhdpi',2),('xxhdpi',3),('xxxhdpi',4)]:
            data=(RES/f'mipmap-{density}/ic_fg.png').read_bytes()
            self.assertEqual(struct.unpack('>II',data[16:24]),(108*scale,108*scale))

    def test_original_non_scaling_controls_are_rejected(self):
        source=(RES/'drawable/ic_launcher_foreground.xml').read_text()
        bad = [source.replace('android:gravity="fill"','android:gravity="center"'),
               source.replace('<item>','<item android:width="70dp" android:height="70dp">',1)]
        for candidate in bad:
            with self.subTest(candidate=candidate), self.assertRaises(AssertionError):
                verify_foreground(ET.fromstring(candidate))

    def test_real_alpha_with_masks_and_old_translation_negative_control(self):
        icon=ET.parse(RES/'mipmap-anydpi-v26/ic_launcher.xml')
        attrs=icon.find('foreground/inset').attrib
        offsets=[float(attrs[A+k].removesuffix('%'))/100 for k in ['insetLeft','insetTop','insetRight','insetBottom']]
        def project(points,size,values):
            # Android InsetDrawable uses integer truncation on each boundary.
            l,t,r,b=[int(size*v) for v in values]
            return [(l+x/108*(size-l-r),t+y/108*(size-t-b),weight) for x,y,weight in points]

        def check_visible(projected,size):
            for mask in ['circle','square','squircle']:
                radius=size/3
                for x,y,weight in projected:
                    dx=abs(x-size/2);dy=abs(y-size/2)
                    if mask=='square': inside=max(dx,dy)<=radius
                    else:
                        exponent=4 if mask=='squircle' else 2
                        inside=(dx/radius)**exponent+(dy/radius)**exponent<=1
                    self.assertTrue(inside,(size,mask,x,y))

        for density in ['mdpi','hdpi','xhdpi','xxhdpi','xxxhdpi']:
            w,h,rows=rgba(RES/f'mipmap-{density}/ic_fg.png')
            points=[]
            for y in range(h):
                for x in range(w):
                    px=(x+.5)*108/w; py=(y+.5)*108/h
                    if (px-54)**2+(py-54)**2 < 35**2:
                        weight=1-rows[y][x*4+3]/255
                        if weight: points.append((px,py,weight))
            self.assertTrue(points)
            for size in [24,36,48,72,108,192,432]:
                with self.subTest(density=density,size=size):
                    projected=project(points,size,offsets)
                    check_visible(projected,size)  # No loss in actual static masks.
                    # The 66dp safe circle is more conservative than the visible
                    # 72dp mask. Independent boundary truncation can use <1px
                    # of its margin; never claim that this is zero safe-zone loss.
                    safe_radius=size*33/108
                    max_radius=max(math.hypot(x-size/2,y-size/2) for x,y,weight in projected)
                    self.assertLessEqual(max_radius,safe_radius+1)
                    total=sum(weight for x,y,weight in projected)
                    cx=sum(x*weight for x,y,weight in projected)/total
                    cy=sum(y*weight for x,y,weight in projected)/total
                    # Source-density rasterization plus a pixel of boundary rounding.
                    tolerance=0.6*size/108+1
                    self.assertLess(abs(cx-size/2),tolerance)
                    self.assertLess(abs(cy-size/2),tolerance)
            bad=project(points,432,[.004,-.056,-.004,.056])
            with self.assertRaises(AssertionError): check_visible(bad,432)
            lost=sum(weight for x,y,weight in bad if (x-216)**2+(y-216)**2>144**2)/sum(weight for x,y,weight in bad)
            self.assertGreater(lost,0.0)

    def test_icon_background_is_separate_from_both_splash_themes(self):
        colors={c.get('name'):c.text for c in ET.parse(RES/'values/ic_launcher_background.xml').getroot()}
        self.assertEqual(colors['ic_launcher_background'],'#FFFFFF')
        self.assertEqual(colors['xb_launcher_icon_background'],'#D92E1A')
        for name in ['ic_launcher.xml','ic_launcher_round.xml']:
            icon=ET.parse(RES/'mipmap-anydpi-v26'/name).getroot()
            self.assertEqual(icon.find('background').get(A+'drawable'),'@color/xb_launcher_icon_background')
            inset = icon.find('foreground/inset')
            self.assertEqual(inset.get(A+'drawable'),'@drawable/ic_launcher_foreground')
            values = {k: float(inset.get(A+k).removesuffix('%')) / 100 for k in ['insetLeft','insetRight','insetTop','insetBottom']}
            self.assertAlmostEqual(values['insetLeft']+values['insetRight'], 0.22)
            self.assertAlmostEqual(values['insetTop']+values['insetBottom'], 0.22)
            for size in [24, 36, 48, 72, 108, 192, 432]:
                left=int(size*values['insetLeft']);right=int(size*values['insetRight'])
                top=int(size*values['insetTop']);bottom=int(size*values['insetBottom'])
                self.assertLessEqual(abs((size-left-right)/size - 0.78), 2/size)
                self.assertLessEqual(abs((size-top-bottom)/size - 0.78), 2/size)
        for folder,color in [('values-v27','@color/ic_launcher_background'),('values-night-v27','#121212')]:
            theme=ET.parse(ROOT/f'android/app/src/main/res/{folder}/styles.xml')
            values={i.get('name'):i.text for i in theme.findall('.//item')}
            self.assertEqual(values['android:windowSplashScreenBackground'],color)
            self.assertEqual(values['android:windowSplashScreenAnimatedIcon'],'@drawable/ic_launcher_foreground')

if __name__ == '__main__':
    unittest.main()
