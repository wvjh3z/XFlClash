import 'dart:typed_data';

import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

import '../../ui/icons/icons.dart';
import '../services/payment_channel_icon_loader.dart';

/// A stable, decorative slot; the channel name remains the accessible label.
class XbPaymentChannelIcon extends StatefulWidget {
  const XbPaymentChannelIcon({super.key, required this.url});

  final String? url;

  @override
  State<XbPaymentChannelIcon> createState() => _XbPaymentChannelIconState();
}

class _XbPaymentChannelIconState extends State<XbPaymentChannelIcon> {
  Future<({Uint8List bytes, bool isSvg})?>? _image;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant XbPaymentChannelIcon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _load();
  }

  void _load() {
    final uri = Uri.tryParse(widget.url ?? '');
    _image = uri == null || !uri.hasScheme ? null : loadPaymentChannelIcon(uri);
  }

  @override
  Widget build(BuildContext context) {
    const size = 23.0;
    final fallback = GlyphIcon(
      AppGlyphs.photos,
      size: 20,
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: 24,
        child: Center(
          child: FutureBuilder(
            future: _image,
            builder: (context, snapshot) {
              final image = snapshot.data;
              if (snapshot.connectionState != ConnectionState.done ||
                  image == null) {
                return fallback;
              }
              final url = Uri.tryParse(widget.url ?? '');
              Widget onInvalid(BuildContext _, Object error, StackTrace? stack) {
                if (url != null) rejectPaymentChannelIcon(url, image.bytes);
                return fallback;
              }
              return image.isSvg
                  ? SvgPicture.memory(
                      image.bytes,
                      width: size,
                      height: size,
                      placeholderBuilder: (_) => fallback,
                      errorBuilder: onInvalid,
                    )
                  : Image(
                      image: ResizeImage(
                        MemoryImage(image.bytes),
                        width: 96,
                        height: 96,
                        policy: ResizeImagePolicy.fit,
                      ),
                      width: size,
                      height: size,
                      fit: BoxFit.contain,
                      frameBuilder: (_, child, frame, synchronous) =>
                          synchronous || frame != null ? child : fallback,
                      errorBuilder: onInvalid,
                    );
            },
          ),
        ),
      ),
    );
  }
}
