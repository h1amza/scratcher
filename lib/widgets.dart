import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:scratcher/painter.dart';
import 'package:scratcher/utils.dart';

const _progressReportStep = 0.1;

/// How accurate should the progress be tracked.
enum ScratchAccuracy {
  /// Low accuracy, higher performance.
  low,

  /// Medium accuracy, medium performance
  medium,

  /// High accuracy, lower performance.
  high,
}

double _getAccuracyValue(ScratchAccuracy accuracy) {
  switch (accuracy) {
    case ScratchAccuracy.low:
      return 10.0;
    case ScratchAccuracy.medium:
      return 30.0;
    case ScratchAccuracy.high:
      return 100.0;
  }
}

/// Scratcher widget which covers given child with scratchable overlay.
class Scratcher extends StatefulWidget {
  Scratcher({
    Key? key,
    required this.child,
    this.enabled = true,
    this.threshold,
    this.brushSize = 25,
    this.accuracy = ScratchAccuracy.high,
    this.color = Colors.black,
    this.image,
    this.rebuildOnResize = true,
    this.onChange,
    this.onThreshold,
    this.onScratchStart,
    this.onScratchUpdate,
    this.onScratchEnd,
  }) : super(key: key);

  /// Widget rendered under the scratch area.
  final Widget child;

  /// Whether new scratches can be applied
  final bool enabled;

  /// Percentage level of scratch area which should be revealed to complete.
  final double? threshold;

  /// Size of the brush. The bigger it is the faster user can scratch the card.
  final double brushSize;

  /// Determines how accurate the progress should be reported.
  /// Lower accuracy means higher performance.
  final ScratchAccuracy accuracy;

  /// Color used to cover the child widget.
  final Color color;

  /// Image widget used to cover the child widget.
  final Image? image;

  /// Determines if the scratcher should rebuild itself when space constraints change (resize).
  final bool rebuildOnResize;

  /// Callback called when new part of area is revealed (min 0.1% difference, or progress == 100).
  final Function(double value)? onChange;

  /// Callback called when threshold is reached.
  final VoidCallback? onThreshold;

  /// Callback called when scratching starts
  final VoidCallback? onScratchStart;

  /// Callback called during scratching
  final VoidCallback? onScratchUpdate;

  /// Callback called when scratching ends
  final VoidCallback? onScratchEnd;

  @override
  ScratcherState createState() => ScratcherState();
}

class ScratcherState extends State<Scratcher> {
  late Future<ui.Image?> _imageLoader;
  Offset? _lastPosition;

  List<ScratchPoint?> points = [];
  late Set<Offset> checkpoints;
  Set<Offset> checked = {};
  int totalCheckpoints = 0;
  double progress = 0;
  double progressReported = 0;
  bool thresholdReported = false;
  bool isFinished = false;
  bool canScratch = true;
  Duration? transitionDuration;
  Size? _lastKnownSize;

  RenderBox? get _renderObject {
    return context.findRenderObject() as RenderBox?;
  }

  @override
  void initState() {
    if (widget.image == null) {
      final completer = Completer<ui.Image?>()..complete();
      _imageLoader = completer.future;
    } else {
      _imageLoader = _loadImage(widget.image!);
    }

    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ui.Image?>(
      future: _imageLoader,
      builder: (BuildContext context, AsyncSnapshot<ui.Image?> snapshot) {
        if (snapshot.connectionState != ConnectionState.waiting) {
          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: canScratch
                ? (details) {
                    widget.onScratchStart?.call();
                    if (widget.enabled) {
                      _addPoint(details.localPosition);
                    }
                  }
                : null,
            onPanUpdate: canScratch
                ? (details) {
                    widget.onScratchUpdate?.call();
                    if (widget.enabled) {
                      _addPoint(details.localPosition);
                    }
                  }
                : null,
            onPanEnd: canScratch
                ? (details) {
                    widget.onScratchEnd?.call();
                    if (widget.enabled) {
                      setState(() => points.add(null));
                    }
                  }
                : null,
            child: AnimatedSwitcher(
              duration: transitionDuration ?? Duration.zero,
              child: isFinished
                  ? widget.child
                  : CustomPaint(
                      foregroundPainter: ScratchPainter(
                        image: snapshot.data,
                        imageFit: widget.image == null
                            ? null
                            : widget.image!.fit ?? BoxFit.cover,
                        points: points,
                        color: widget.color,
                        onDraw: (size) {
                          if (_lastKnownSize == null) {
                            _setCheckpoints(size);
                          } else if (_lastKnownSize != size &&
                              widget.rebuildOnResize) {
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              reset();
                            });
                          }

                          _lastKnownSize = size;
                        },
                      ),
                      child: widget.child,
                    ),
            ),
          );
        }

        return Container();
      },
    );
  }

  Future<ui.Image> _loadImage(Image image) async {
    // Create a completer to manage the asynchronous operation.
    final Completer<ui.Image> imageCompleter = Completer<ui.Image>();

    // Obtain the image provider from the Image widget.
    final ImageProvider imageProvider = image.image;

    // Obtain a key for the image.
    final imageKey = await imageProvider.obtainKey(ImageConfiguration.empty);

    // Load the image using the obtained key.
    imageProvider.loadImage(
      imageKey,
          (ui.ImmutableBuffer buffer, {ui.TargetImageSizeCallback? getTargetSize}) {
        return ui.instantiateImageCodecFromBuffer(buffer);
      },
    ).addListener(ImageStreamListener((ImageInfo image, _) {
      imageCompleter.complete(image.image);
    }));

    // Return the future from the completer.
    return imageCompleter.future;
  }

  bool _inCircle(Offset center, Offset point, double radius) {
    final dX = center.dx - point.dx;
    final dY = center.dy - point.dy;
    final multi = dX * dX + dY * dY;
    final distance = sqrt(multi).roundToDouble();

    return distance <= radius;
  }

  void _addPoint(Offset position) {
    // Ignore when same point is reported multiple times in a row
    if (_lastPosition == position) {
      return;
    }
    _lastPosition = position;

    ui.Offset? point = position;
    final scratchPoint = ScratchPoint(point, widget.brushSize);

    // Ignore when starting point of new line has been already scratched
    if (points.isNotEmpty && points.contains(scratchPoint)) {
      if (points.last == null) {
        return;
      } else {
        point = null;
      }
    }

    setState(() {
      points.add(scratchPoint);
    });

    if (point != null && !checked.contains(point)) {
      checked.add(point);

      final radius = widget.brushSize / 2;
      checkpoints.removeWhere(
        (checkpoint) => _inCircle(checkpoint, point!, radius),
      );

      progress =
          ((totalCheckpoints - checkpoints.length) / totalCheckpoints) * 100;
      if (progress - progressReported >= _progressReportStep ||
          progress == 100) {
        progressReported = progress;
        widget.onChange?.call(progress);
      }

      if (!thresholdReported &&
          widget.threshold != null &&
          progress >= widget.threshold!) {
        thresholdReported = true;
        widget.onThreshold?.call();
      }

      if (progress == 100) {
        isFinished = true;
      }
    }
  }

  void _setCheckpoints(Size size) {
    final calculated = _calculateCheckpoints(size).toSet();

    checkpoints = calculated;
    totalCheckpoints = calculated.length;
  }

  List<Offset> _calculateCheckpoints(Size size) {
    final accuracy = _getAccuracyValue(widget.accuracy);
    final xOffset = size.width / accuracy;
    final yOffset = size.height / accuracy;

    final points = <Offset>[];
    for (var x = 0; x < accuracy; x++) {
      for (var y = 0; y < accuracy; y++) {
        final point = Offset(
          x * xOffset,
          y * yOffset,
        );
        points.add(point);
      }
    }

    return points;
  }

  /// Resets the scratcher state to the initial values.
  void reset({Duration? duration}) {
    setState(() {
      transitionDuration = duration;
      isFinished = false;
      canScratch = duration == null;
      thresholdReported = false;

      _lastPosition = null;
      points = [];
      checked = {};
      progress = 0;
      progressReported = 0;
    });

    // Do not allow to scratch during transition
    if (duration != null) {
      Future.delayed(duration, () {
        setState(() {
          canScratch = true;
        });
      });
    }

    _setCheckpoints(_renderObject!.size);
    widget.onChange?.call(0);
  }

  /// Reveals the whole scratcher, so than only original child is displayed.
  void reveal({Duration? duration}) {
    setState(() {
      transitionDuration = duration;
      isFinished = true;
      canScratch = false;
      if (!thresholdReported && widget.threshold != null) {
        thresholdReported = true;
        widget.onThreshold?.call();
      }
    });

    widget.onChange?.call(100);
  }
}
