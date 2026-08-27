import '../services/ipc/dto.dart';

/// A node in the file tree shown during send preparation and in transfer
/// history. Directories are markers carrying their subtree; leaves carry size
/// and (when the daemon recorded one) the absolute path on disk.
class FileTreeNode {
  final String name; /// Display name (leaf component of the path)
  final String relativePath; /// Full relative path from the root
  final String? fullPath; /// Absolute path on disk (null for virtual nodes)
  final int size; /// 0 for directory nodes
  final bool isDir; /// true for directory markers
  final List<FileTreeNode> children;

  const FileTreeNode({
    required this.name,
    required this.relativePath,
    this.fullPath,
    this.size = 0,
    this.isDir = false,
    this.children = const [],
  });

  /// Total number of files (non-dir) in this subtree.
  int get fileCount {
    if (!isDir) return 1;
    return children.fold(0, (sum, c) => sum + c.fileCount);
  }

  /// Total size of all files in this subtree.
  int get totalSize {
    if (!isDir) return size;
    return children.fold(0, (sum, c) => sum + c.totalSize);
  }
}

/// Build a tree from a flat map of relative paths to sizes (sizes only — e.g.
/// an incoming offer where only the file names and sizes are known).
List<FileTreeNode> buildFileTreeFromSizedPaths(Map<String, int> pathSizes) {
  final pathMap = <String, _RecordEntry>{};
  for (final entry in pathSizes.entries) {
    pathMap[entry.key] = _RecordEntry(size: entry.value);
  }
  return _buildTreeFromMap(pathMap, '');
}

/// Build a tree from `HistoryDetailDto.files`, preserving each leaf's absolute
/// path so the history page can offer "Open file" where the daemon recorded one.
List<FileTreeNode> buildFileTreeFromHistoryFiles(List<HistoryFileDto> files) {
  final pathMap = <String, _RecordEntry>{};
  for (final f in files) {
    pathMap[f.relativePath] = _RecordEntry(fullPath: f.absolutePath, size: f.size);
  }
  return _buildTreeFromMap(pathMap, '');
}

/// Build a tree from a flat list of relative paths; each path is split by '/'
/// to create nested nodes. [dirPaths] optionally marks empty directories.
List<FileTreeNode> buildFileTreeFromPaths(List<String> relativePaths,
    {Set<String>? dirPaths}) {
  dirPaths ??= <String>{};
  final root = <String, List<String>>{};

  for (final path in relativePaths) {
    final parts = path.split('/');
    if (parts.isEmpty) continue;
    final fileName = parts.last;
    final dirParts = parts.sublist(0, parts.length - 1);
    final dirKey = dirParts.join('/');
    root.putIfAbsent(dirKey, () => []).add(fileName);
  }

  return _buildTreeNodes(root, '', dirPaths);
}

List<FileTreeNode> _buildTreeNodes(
    Map<String, List<String>> lookup, String prefix, Set<String> dirPaths) {
  final result = <FileTreeNode>[];

  final dirs = <String>{};
  final files = <String>[];

  for (final entry in lookup.entries) {
    final dirPath = entry.key;
    if (dirPath == prefix) {
      for (final fileName in entry.value) {
        if (dirPaths.contains('$prefix/$fileName')) {
          dirs.add('$prefix/$fileName');
        } else {
          files.add(fileName);
        }
      }
    } else if (dirPath.startsWith(prefix) && prefix.length < dirPath.length) {
      final rest = dirPath.substring(prefix.isEmpty ? 0 : prefix.length + 1);
      if (!rest.contains('/')) {
        dirs.add(dirPath);
      }
    }
  }

  final sortedDirs = dirs.toList()..sort();
  for (final dirPath in sortedDirs) {
    final dirName = dirPath.contains('/') ? dirPath.split('/').last : dirPath;
    final children = _buildTreeNodes(lookup, dirPath, dirPaths);
    result.add(FileTreeNode(
      name: dirName,
      relativePath: dirPath,
      isDir: true,
      children: children,
    ));
  }

  files.sort();
  for (final fileName in files) {
    final fullPath = prefix.isEmpty ? fileName : '$prefix/$fileName';
    result.add(FileTreeNode(
      name: fileName,
      relativePath: fullPath,
      isDir: false,
    ));
  }

  return result;
}

class _RecordEntry {
  final String? fullPath;
  final int size;
  const _RecordEntry({this.fullPath, this.size = 0});
}

List<FileTreeNode> _buildTreeFromMap(Map<String, _RecordEntry> pathMap, String prefix) {
  // Group paths at the current level by their first path component.
  final groups = <String, List<String>>{};
  for (final relPath in pathMap.keys) {
    if (relPath == prefix) continue;
    // Non-empty prefix must match with trailing '/' to avoid treating sibling
    // paths like "colors.json" as children of "colors".
    if (prefix.isNotEmpty && !relPath.startsWith('$prefix/')) continue;
    final rest = prefix.isEmpty ? relPath : relPath.substring(prefix.length + 1);
    final first = rest.split('/').first;
    groups.putIfAbsent(first, () => []).add(relPath);
  }

  final result = <FileTreeNode>[];
  final sortedNames = groups.keys.toList()..sort();
  for (final name in sortedNames) {
    final fullPath = prefix.isEmpty ? name : '$prefix/$name';
    final subPaths = groups[name]!;
    final entry = pathMap[fullPath];

    final isDir = subPaths.any((p) => p != fullPath);

    if (isDir) {
      final children = _buildTreeFromMap(pathMap, fullPath);
      final dirSize = children.fold(0, (sum, c) => sum + c.size);
      result.add(FileTreeNode(
        name: name,
        relativePath: fullPath,
        fullPath: entry?.fullPath,
        size: dirSize,
        isDir: true,
        children: children,
      ));
    } else {
      result.add(FileTreeNode(
        name: name,
        relativePath: fullPath,
        fullPath: entry?.fullPath,
        size: entry?.size ?? 0,
      ));
    }
  }

  return result;
}
