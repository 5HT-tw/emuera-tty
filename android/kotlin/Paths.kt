package io.github.astartes_gaming.emuera

import java.io.File
import java.io.FileNotFoundException

/**
 * The file `id` names under `root`, which must be canonical. Ids come from outside the app, so
 * this must not lead anywhere else: `..` and symlinks are followed first, then checked.
 * Tested by tools/paths_test.kt.
 */
fun inside(root: File, id: String): File {
    val f = File(root, id).canonicalFile
    if (f != root && !f.path.startsWith(root.path + File.separator)) throw FileNotFoundException(id)
    return f
}

/**
 * A safe folder name for a game, from a file name from outside the app: it becomes a path, and a
 * leading dot would hide it from the list, or worse (recoverImports treats `.old-NAME` as NAME's old copy).
 * Tested by tools/paths_test.kt.
 */
fun cleanName(raw: String) = raw.replace('/', '_').replace('\u0000', '_').trimStart('.', ' ').trimEnd().ifBlank { "game" }
