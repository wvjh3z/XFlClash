"""Adaptive launcher geometry and splash isolation; stdlib only, no APK build."""
from pathlib import Path
import sys
import unittest
import xml.etree.ElementTree as ET
sys.path.insert(0, str(Path(__file__).resolve().parent))
from icon_png_reader import rgba

ROOT = Path(__file__).resolve().parents[2]
RES = ROOT / 'android/app/src/brand_b/res'
A = '{http://schemas.android.com/apk/res/android}'
DENSITIES = [('mdpi', 1), ('hdpi', 1.5), ('xhdpi', 2), ('xxhdpi', 3), ('xxxhdpi', 4)]
SIZES = [24, 36, 48, 72, 108, 192, 432]


def verify_splash(root):
    assert root.tag == 'layer-list'
    items = root.findall('item')
    assert len(items) == 2
    for item in items:
        assert not any(A + k in item.attrib for k in ('width', 'height', 'gravity', 'left', 'right', 'top', 'bottom'))
    vector = items[0].find('vector')
    assert vector.get(A+'viewportWidth') == vector.get(A+'viewportHeight') == '108'
    assert vector.get(A+'width') == vector.get(A+'height') == '108dp'
    path = vector.find('path')
    assert path.get(A+'fillColor') == '#FFFFFF'
    assert path.get(A+'pathData') == 'M54,19 a35,35 0,1 0,0,70 a35,35 0,1 0,0,-70'
    bitmap = items[1].find('bitmap')
    assert bitmap.get(A+'src') == '@mipmap/ic_fg'
    assert bitmap.get(A+'gravity') == 'fill'


def verify_launcher(root, colors):
    assert root.tag == 'adaptive-icon'
    assert root.find('background').get(A+'drawable') == '@color/xb_launcher_icon_background'
    assert colors['xb_launcher_icon_background'].upper() == '#FFFFFF'
    inset = root.find('foreground/inset')
    assert inset is not None
    # The splash's independent white disc must not enter the launcher graph.
    assert inset.get(A+'drawable') == '@mipmap/ic_fg'
    assert len(inset) == 0
    offsets = tuple(float(inset.get(A+k).removesuffix('%')) / 100
                    for k in ['insetLeft', 'insetTop', 'insetRight', 'insetBottom'])
    assert all(abs(x-y) < 1e-9 for x, y in zip(offsets, (.04, .025, .04, .055)))
    return offsets


def projected(points, size, offsets):
    left, top, right, bottom = [int(size*v) for v in offsets]
    return [(left+x*(size-left-right), top+y*(size-top-bottom), alpha)
            for x, y, alpha in points]


def check_geometry(points, size, offsets):
    output = projected(points, size, offsets)
    total = sum(a for _, _, a in output)
    assert total > 0
    for exponent in [2, 4, None]:  # circle, squircle, square, all in the central 72dp mask
        lost = 0
        for x, y, alpha in output:
            dx, dy = abs(x-size/2), abs(y-size/2)
            radius = size/3
            inside = (max(dx, dy) <= radius if exponent is None else
                      (dx/radius)**exponent + (dy/radius)**exponent <= 1)
            if not inside:
                # Integer inset rounding can trim a tiny antialias fringe, never solid artwork.
                assert alpha < 128
                lost += alpha
        assert lost / total <= 0.0005
    # Compare the whole red artwork's bounds, not the transparent kangaroo's centroid.
    cx = (min(x for x, _, _ in output) + max(x for x, _, _ in output)) / 2
    cy = (min(y for _, y, _ in output) + max(y for _, y, _ in output)) / 2
    tolerance = .6 * size / 108 + 1  # source rasterization + independent integer inset rounding
    assert abs(cx-size*.5) <= tolerance
    assert abs(cy-size*.485) <= tolerance


class IconResourcesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.colors = {c.get('name'): c.text for c in ET.parse(RES/'values/ic_launcher_background.xml').getroot()}
        cls.samples = {}
        for density, scale in DENSITIES:
            width, height, rows = rgba(RES/f'mipmap-{density}/ic_fg.png')
            assert (width, height) == (108*scale, 108*scale)
            points = []
            for y in range(height):
                for x in range(width):
                    red, green, blue, alpha = rows[y][4*x:4*x+4]
                    if alpha:
                        points.append(((x+.5)/width, (y+.5)/height, alpha))
                        if alpha >= 128:
                            assert red > 150 and green < 100 and blue < 100
            cls.samples[density] = points

    def test_both_launcher_variants_all_densities_and_small_sizes(self):
        for name in ['ic_launcher.xml', 'ic_launcher_round.xml']:
            offsets = verify_launcher(ET.parse(RES/'mipmap-anydpi-v26'/name).getroot(), self.colors)
            for density, points in self.samples.items():
                for size in SIZES:
                    with self.subTest(name=name, density=density, size=size):
                        check_geometry(points, size, offsets)

    def test_old_disc_red_background_and_alignment_are_rejected(self):
        source = (RES/'mipmap-anydpi-v26/ic_launcher.xml').read_text()
        variants = [source.replace('@mipmap/ic_fg', '@drawable/ic_launcher_foreground'),
                    source.replace('insetTop="2.5%"', 'insetTop="4%"').replace('insetBottom="5.5%"', 'insetBottom="4%"'),
                    source.replace('insetLeft="4%"', 'insetLeft="11.32%"')]
        for variant in variants:
            with self.subTest(variant=variant), self.assertRaises(AssertionError):
                verify_launcher(ET.fromstring(variant), self.colors)
        with self.assertRaises(AssertionError):
            verify_launcher(ET.fromstring(source), {**self.colors, 'xb_launcher_icon_background': '#D92E1A'})

    def test_real_geometry_rejects_downshift_and_oversize(self):
        for density, points in self.samples.items():
            with self.subTest(density=density):
                with self.assertRaises(AssertionError):
                    check_geometry(points, 432, (.04, .04, .04, .04))
                with self.assertRaises(AssertionError):
                    check_geometry(points, 432, (.04, .055, .04, .025))
                with self.assertRaises(AssertionError):
                    check_geometry(points, 432, (.004, -.056, -.004, .056))

    def test_old_white_disc_exposes_pixels_above_red_artwork(self):
        # Regression evidence for the original two-layer halo, independent of the new inset.
        for density, points in self.samples.items():
            central_top = min(y for x, y, a in points if abs(x-.5) < .02 and a >= 128)
            self.assertGreater(central_top * 108, 19)

    def test_splash_and_monochrome_notification_are_separate(self):
        verify_splash(ET.parse(RES/'drawable/ic_launcher_foreground.xml').getroot())
        self.assertEqual(self.colors['ic_launcher_background'], '#FFFFFF')
        for folder, color in [('values-v27', '@color/ic_launcher_background'), ('values-night-v27', '#121212')]:
            theme = ET.parse(ROOT/f'android/app/src/main/res/{folder}/styles.xml')
            values = {i.get('name'): i.text for i in theme.findall('.//item')}
            self.assertEqual(values['android:windowSplashScreenBackground'], color)
            self.assertEqual(values['android:windowSplashScreenAnimatedIcon'], '@drawable/ic_launcher_foreground')
        aliases = {i.get('name'): i.text for i in ET.parse(RES/'values/xb_system_icons.xml').getroot()}
        self.assertEqual(aliases['ic_service'], '@drawable/xb_brand_system_icon')
        self.assertEqual(aliases['ic'], '@drawable/xb_brand_system_icon')
        for folder in ['drawable', 'drawable-hdpi', 'drawable-xhdpi', 'drawable-xxhdpi', 'drawable-xxxhdpi']:
            self.assertTrue((RES/folder/'xb_brand_system_icon.png').is_file())
        manifest = ET.parse(ROOT/'android/app/src/main/AndroidManifest.xml')
        self.assertEqual(manifest.find('application').get(A+'icon'), '@mipmap/ic_launcher')

    def test_splash_fixed_size_negative_controls_still_fail(self):
        source = (RES/'drawable/ic_launcher_foreground.xml').read_text()
        for candidate in [source.replace('android:gravity="fill"', 'android:gravity="center"'),
                          source.replace('<item>', '<item android:width="70dp" android:height="70dp">', 1)]:
            with self.assertRaises(AssertionError): verify_splash(ET.fromstring(candidate))

if __name__ == '__main__':
    unittest.main()
