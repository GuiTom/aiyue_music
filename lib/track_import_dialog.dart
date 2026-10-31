part of 'main.dart';

class TrackImportDialog extends StatefulWidget {
  const TrackImportDialog({super.key, required this.tracks});
  final List<LocalTrack> tracks;
  @override
  State<TrackImportDialog> createState() => _TrackImportDialogState();
}

class _TrackImportDialogState extends State<TrackImportDialog> {
  final selected = <String>{};
  String query = '';

  @override
  Widget build(BuildContext context) {
    final visible = widget.tracks
        .where((t) => t.name.toLowerCase().contains(query.toLowerCase()))
        .toList();
    final allVisible =
        visible.isNotEmpty && visible.every((t) => selected.contains(t.path));
    return AlertDialog(
      title: const Text('选择要导入的 MP3'),
      content: SizedBox(
        width: 520,
        height: MediaQuery.sizeOf(context).height * .55,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '找到 ${widget.tracks.length} 首 · 已选 ${selected.length} 首',
              style: const TextStyle(color: muted),
            ),
            const SizedBox(height: 12),
            TextField(
              onChanged: (v) => setState(() => query = v),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索文件名',
                isDense: true,
              ),
            ),
            Row(
              children: [
                TextButton(
                  onPressed: visible.isEmpty
                      ? null
                      : () => setState(() {
                          for (final track in visible) {
                            if (allVisible) {
                              selected.remove(track.path);
                            } else {
                              selected.add(track.path);
                            }
                          }
                        }),
                  child: Text(
                    allVisible
                        ? '取消全选${query.isEmpty ? '' : '搜索结果'}'
                        : '全选${query.isEmpty ? '' : '搜索结果'}',
                  ),
                ),
                const Spacer(),
                if (selected.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(selected.clear),
                    child: const Text('清空选择'),
                  ),
              ],
            ),
            Expanded(
              child: visible.isEmpty
                  ? const Center(child: Text('没有匹配的 MP3'))
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, index) {
                        final track = visible[index];
                        return CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          controlAffinity: ListTileControlAffinity.leading,
                          value: selected.contains(track.path),
                          title: Text(
                            track.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onChanged: (value) => setState(() {
                            if (value == true) {
                              selected.add(track.path);
                            } else {
                              selected.remove(track.path);
                            }
                          }),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: selected.isEmpty
              ? null
              : () => Navigator.pop(
                  context,
                  widget.tracks
                      .where((t) => selected.contains(t.path))
                      .toList(),
                ),
          child: Text('导入 ${selected.length} 首'),
        ),
      ],
    );
  }
}
