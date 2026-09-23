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

/// 图片筛选栏（可折叠）。
///
/// 收起时只占一行摘要，展开后各筛选控件分组纵向排布；格式/来源 chip 用 [Wrap]
/// 自动换行，因此再窄的面板也不会横向被截断。
class FilterBar extends StatefulWidget {
  const FilterBar({super.key, required this.capture});

  final CaptureController capture;

  @override
  State<FilterBar> createState() => _FilterBarState();
}

class _FilterBarState extends State<FilterBar> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.capture,
      builder: (context, _) {
        final capture = widget.capture;
        final filter = capture.filter;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _SummaryRow(
              summary: _summaryOf(filter),
              expanded: _expanded,
              showReset: !capture.isFilterDefault,
              onToggle: () => setState(() => _expanded = !_expanded),
              onReset: capture.resetFilter,
            ),
            if (_expanded) ...[
              const Divider(height: 1),
              LayoutBuilder(
                builder: (context, constraints) {
                  // 预留摘要行、分隔线和面板操作栏的高度；筛选体最多占剩余
                  // 空间，装不下时只在内部纵向滚动，避免把面板 Column 撑爆。
                  final remaining = constraints.hasBoundedHeight
                      ? (constraints.maxHeight - 140).clamp(0.0, double.infinity)
                      : 400.0;
                  return ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: remaining),
                    child: SingleChildScrollView(
                      child: _FilterBody(capture: capture, filter: filter),
                    ),
                  );
                },
              ),
            ],
          ],
        );
      },
    );
  }

  String _summaryOf(FilterSettings filter) {
    return '最小边 ${filter.minSide}px'
        ' · 格式 ${filter.enabledFormats.length}/${kAllFormats.length}'
        ' · 来源 ${filter.enabledSources.length}/${kSourceLabels.length}'
        ' · 去重${filter.mergeVariants ? '开' : '关'}';
  }
}

/// 始终可见的摘要行：点击整行展开/收起。
class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.summary,
    required this.expanded,
    required this.showReset,
    required this.onToggle,
    required this.onReset,
  });

  final String summary;
  final bool expanded;
  final bool showReset;
  final VoidCallback onToggle;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 10, right: 4),
      child: Row(
        children: [
          // 展开/收起的手势只包住摘要部分，重置按钮是它的兄弟节点，
          // 避免两个手势区域嵌套导致点击互相抢占。
          Expanded(
            child: InkWell(
              key: const Key('filter-toggle'),
              onTap: onToggle,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.tune,
                      size: 18,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Text('筛选', style: theme.textTheme.titleSmall),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        summary,
                        key: const Key('filter-summary'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (showReset)
            TextButton(
              key: const Key('filter-reset'),
              onPressed: onReset,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('重置'),
            ),
        ],
      ),
    );
  }
}

/// 展开后的筛选控件：尺寸 / 去重 / 格式 / 来源。
class _FilterBody extends StatelessWidget {
  const _FilterBody({required this.capture, required this.filter});

  final CaptureController capture;
  final FilterSettings filter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('最小边', style: theme.textTheme.bodySmall),
              Expanded(
                child: Slider(
                  key: const Key('min-side-slider'),
                  value: filter.minSide.clamp(0, 512).toDouble(),
                  max: 512,
                  divisions: 16,
                  label: '${filter.minSide}px',
                  onChanged: (value) => capture.setMinSide(value.round()),
                ),
              ),
              SizedBox(
                width: 44,
                child: Text(
                  '${filter.minSide}px',
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          Row(
            children: [
              Text('尺寸去重', style: theme.textTheme.bodySmall),
              const Spacer(),
              Switch(
                key: const Key('dedupe-switch'),
                value: filter.mergeVariants,
                onChanged: capture.setMergeVariants,
              ),
            ],
          ),
          const SizedBox(height: 4),
          _Section(
            title: '格式',
            children: [
              for (final format in kAllFormats)
                _buildChip(
                  key: Key('format-chip-$format'),
                  label: format.toUpperCase(),
                  selected: filter.enabledFormats.contains(format),
                  onToggle: () => capture.toggleFormat(format),
                ),
            ],
          ),
          const SizedBox(height: 10),
          _Section(
            title: '来源',
            children: [
              for (final entry in kSourceLabels.entries)
                _buildChip(
                  key: Key('source-chip-${entry.key.name}'),
                  label: entry.value,
                  selected: filter.enabledSources.contains(entry.key),
                  onToggle: () => capture.toggleSource(entry.key),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// 紧凑 chip：默认 M3 样式高 48px，分组一多就把窄面板的筛选区撑得过高。
  Widget _buildChip({
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onToggle,
  }) {
    return FilterChip(
      key: key,
      label: Text(label),
      selected: selected,
      onSelected: (_) => onToggle(),
      visualDensity: VisualDensity.compact,
      labelStyle: const TextStyle(fontSize: 13),
      labelPadding: EdgeInsets.zero,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
    );
  }
}

/// 带小标题的一组 chip，整体自动换行。
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: children),
      ],
    );
  }
}
