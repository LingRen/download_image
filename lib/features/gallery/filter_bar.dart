import 'package:flutter/material.dart';

import '../../core/model/image_asset.dart';
import '../capture/capture_controller.dart';
import '../capture/image_filter.dart';

const Map<ImageSource, String> kSourceLabels = {
  ImageSource.img: '<img>',
  ImageSource.srcset: 'srcset',
  ImageSource.cssBackground: 'CSS 背景图',
  ImageSource.dynamic: '动态加载',
};

class FilterBar extends StatelessWidget {
  const FilterBar({super.key, required this.capture});

  final CaptureController capture;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: capture,
      builder: (context, _) {
        final filter = capture.filter;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Row(
                  children: [
                    Text('尺寸去重', style: Theme.of(context).textTheme.bodySmall),
                    Switch(
                      key: const Key('dedupe-switch'),
                      value: filter.mergeVariants,
                      onChanged: capture.setMergeVariants,
                    ),
                  ],
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 180,
                  child: Row(
                    children: [
                      Text('最小边', style: Theme.of(context).textTheme.bodySmall),
                      Expanded(
                        child: Slider(
                          key: const Key('min-side-slider'),
                          value: filter.minSide.clamp(0, 512).toDouble(),
                          max: 512,
                          divisions: 16,
                          label: '${filter.minSide}px',
                          onChanged: (value) =>
                              capture.setMinSide(value.round()),
                        ),
                      ),
                      Text(
                        '${filter.minSide}px',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                for (final format in kAllFormats)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: FilterChip(
                      key: Key('format-chip-$format'),
                      label: Text(format.toUpperCase()),
                      selected: filter.enabledFormats.contains(format),
                      onSelected: (_) => capture.toggleFormat(format),
                    ),
                  ),
                const SizedBox(width: 8),
                for (final entry in kSourceLabels.entries)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: FilterChip(
                      key: Key('source-chip-${entry.key.name}'),
                      label: Text(entry.value),
                      selected: filter.enabledSources.contains(entry.key),
                      onSelected: (_) => capture.toggleSource(entry.key),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
