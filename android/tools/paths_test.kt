// Checks GamesProvider's path rule and the import's folder names off the phone. From app/:
//
//   nix shell nixpkgs#kotlin nixpkgs#jdk21_headless -c sh -c 'kotlinc -nowarn kotlin/Paths.kt tools/paths_test.kt -include-runtime -d /tmp/paths.jar && java -cp /tmp/paths.jar io.github.astartes_gaming.emuera.Paths_testKt'
package io.github.astartes_gaming.emuera

import java.io.File
import java.io.FileNotFoundException
import java.nio.file.Files

fun main() {
    val base = Files.createTempDirectory("paths").toFile().canonicalFile
    val root = File(base, "games").apply { mkdirs() }
    File(root, "game/sav").mkdirs()
    File(base, "games-sibling").mkdirs()
    Files.createSymbolicLink(File(root, "out").toPath(), base.toPath())
    Files.createSymbolicLink(File(root, "in").toPath(), File(root, "game").toPath())

    fun refused(id: String) = try {
        inside(root, id)
        false
    } catch (e: FileNotFoundException) {
        true
    }

    check(inside(root, ".") == root)
    check(inside(root, "game/sav") == File(root, "game/sav"))
    check(inside(root, "game/sav/../sav") == File(root, "game/sav"))
    check(inside(root, "not/there/yet") == File(root, "not/there/yet"))
    check(inside(root, "in/sav") == File(root, "game/sav"))
    // (Java's File joins this under root instead of going to the real /etc)
    check(inside(root, "/etc/passwd") == File(root, "etc/passwd"))
    for (id in listOf("..", "../", "../secret", "game/../../secret", "game/sav/../../../secret", "../games-sibling", "../games-sibling/x", "out", "out/secret")) {
        check(refused(id)) { "should be refused: $id" }
    }
    base.deleteRecursively()

    // a game's folder name: never hidden, never another game's old copy, never a path
    check(cleanName("AnonTW") == "AnonTW")
    check(cleanName(".old-AnonTW") == "old-AnonTW")
    check(cleanName(". .import-x ") == "import-x")
    check(cleanName("../../etc") == "_.._etc")
    check(cleanName("a\u0000b") == "a_b")
    for (raw in listOf("", " ", ".", "..", "...")) check(cleanName(raw) == "game") { "should be \"game\": \"$raw\"" }
    println("paths: all as expected")
}
