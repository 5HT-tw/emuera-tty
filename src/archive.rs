//! Playing games straight from their download archive.
//!
//! An archive is extracted once into `$XDG_DATA_HOME/emuera-tty/games/<name>/`
//! (default `~/.local/share/…`) and the game folder inside it (the one with
//! `CSV/` and `ERB/`, possibly a few levels down) is played. A marker file
//! records the archive's size and modification time; when the archive
//! changes (a newer release under the same name) it is extracted again and
//! the player's saves are carried over to the new copy ([`keep_saves`]).
//!
//! zip, tar and tar.gz are read in-process. Entries are written one by one
//! with their paths checked: absolute paths and `..` are skipped, as are
//! symlinks and other special files, so an archive can't write outside its
//! folder. Zip names that aren't UTF-8 are decoded as Shift_JIS (Windows
//! zips of Japanese games). Other formats (tar.xz/bz2/zst, 7z, rar) are
//! handed to `bsdtar`, `tar` or `7z` from the system, and any symlinks they
//! create are removed afterwards.

use crate::picker::is_game_dir;
use std::fs;
use std::io;
use std::path::{Component, Path, PathBuf};

/// File name suffixes recognised as archives (lower-case).
const SUFFIXES: &[&str] = &[".zip", ".tar.gz", ".tgz", ".tar", ".tar.xz", ".txz", ".tar.bz2", ".tbz2", ".tar.zst", ".7z", ".rar"];

/// The archive suffix of `path`, if it has one we know.
pub fn suffix(path: &Path) -> Option<&'static str> {
    let name = path.file_name()?.to_string_lossy().to_lowercase();
    SUFFIXES.iter().copied().filter(|s| name.ends_with(s)).max_by_key(|s| s.len())
}

pub fn is_archive(path: &Path) -> bool {
    path.is_file() && suffix(path).is_some()
}

/// `games/<archive name without its suffix>`.
fn dest_for(archive: &Path) -> Option<PathBuf> {
    let name = archive.file_name()?.to_string_lossy().to_string();
    let stem = &name[..name.len() - suffix(archive)?.len()];
    let base = crate::sys::data_base()?;
    Some(base.join("emuera-tty").join("games").join(stem))
}

/// "size mtime" of the archive, to notice when it changes.
fn stamp(archive: &Path) -> String {
    let m = fs::metadata(archive).ok();
    let mtime = m.as_ref().and_then(|m| m.modified().ok()).and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_secs());
    format!("{} {}", m.map_or(0, |m| m.len()), mtime)
}

const MARKER: &str = ".emuera-tty-source";

/// The game folder inside `root`: `root` itself or the first match within
/// three levels (archives often wrap everything in one top folder).
pub fn find_game(root: &Path) -> Option<PathBuf> {
    fn walk(d: &Path, depth: usize) -> Option<PathBuf> {
        if is_game_dir(d) {
            return Some(d.to_path_buf());
        }
        if depth == 0 {
            return None;
        }
        let mut subs: Vec<PathBuf> = fs::read_dir(d).ok()?.flatten().map(|e| e.path()).filter(|p| p.is_dir() && !p.is_symlink()).collect();
        subs.sort();
        subs.iter().find_map(|s| walk(s, depth - 1))
    }
    walk(root, 3)
}

/// The game folder from an earlier extraction, if the archive is unchanged.
pub fn already_extracted(archive: &Path) -> Option<PathBuf> {
    let dest = dest_for(archive)?;
    (fs::read_to_string(dest.join(MARKER)).ok()? == stamp(archive)).then(|| find_game(&dest)).flatten()
}

/// Extract `archive` (or reuse an earlier extraction) and return the game
/// folder to play. `progress` is told how many files have been written.
pub fn extract_game(archive: &Path, progress: &mut dyn FnMut(usize)) -> Result<PathBuf, String> {
    if let Some(g) = already_extracted(archive) {
        return Ok(g);
    }
    let dest = dest_for(archive).ok_or_else(|| t!("can't work out where to extract (HOME not set?)"))?;
    let stamp = stamp(archive);
    let parent = dest.parent().unwrap();
    fs::create_dir_all(parent).map_err(|e| format!("{}: {}", parent.display(), e))?;
    let tmp = parent.join(format!(".{}.partial", dest.file_name().unwrap().to_string_lossy()));
    let _ = fs::remove_dir_all(&tmp);
    fs::create_dir_all(&tmp).map_err(|e| format!("{}: {}", tmp.display(), e))?;
    let result = unpack(archive, &tmp, progress);
    let game = match result.and_then(|()| find_game(&tmp).ok_or_else(|| t!("no Emuera game (a folder with CSV/ and ERB/) in this archive"))) {
        Ok(g) => g,
        Err(e) => {
            let _ = fs::remove_dir_all(&tmp);
            return Err(e);
        }
    };
    // keep the player's saves from an earlier extraction
    if let Some(old) = find_game(&dest) {
        keep_saves(&old, &game)?;
    }
    let rel = game.strip_prefix(&tmp).unwrap_or(Path::new("")).to_path_buf();
    if dest.exists() {
        fs::remove_dir_all(&dest).map_err(|e| format!("{}: {}", dest.display(), e))?;
    }
    fs::rename(&tmp, &dest).map_err(|e| format!("{}: {}", dest.display(), e))?;
    let _ = fs::write(dest.join(MARKER), &stamp);
    Ok(dest.join(rel))
}

/// A save by its name, in the game's own folder: `Vm::save_dir` is that folder unless the
/// game's config turns on the sav folder. saveNN.sav, global.sav, SAVETEXT's txtNN.txt and
/// GSAVE's imgNNNN.png.
fn is_root_save(name: &str) -> bool {
    let name = name.to_ascii_lowercase();
    let numbered = |prefix: &str, ext: &str| {
        name.strip_prefix(prefix).and_then(|n| n.strip_suffix(ext)).is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
    };
    name.ends_with(".sav") || numbered("txt", ".txt") || numbered("img", ".png")
}

/// The player's files in a game's old copy, each with its place in the new one. `dat/` also
/// holds the game's own data (AnonTW's XML files), so only SAVECHARA's files are taken from it.
// shortcut: SAVETEXT with a file name can write anywhere in the game and looks like the game's own files, so those stay behind; carry them too if a game turns out to need it.
fn save_moves(old: &Path, new: &Path) -> io::Result<Vec<(PathBuf, PathBuf)>> {
    let mut moves = vec![];
    if old.join("sav").is_dir() {
        moves.push((old.join("sav"), new.join("sav")));
    }
    let mut add = |dir: &str, is_save: fn(&str) -> bool| -> io::Result<()> {
        if old.join(dir).is_dir() {
            for e in fs::read_dir(old.join(dir))? {
                let e = e?;
                if e.file_type()?.is_file() && is_save(&e.file_name().to_string_lossy()) {
                    moves.push((e.path(), new.join(dir).join(e.file_name())));
                }
            }
        }
        Ok(())
    };
    add("", is_root_save)?;
    add("dat", |n| n.starts_with("chara_") && n.ends_with(".dat"))?;
    Ok(moves)
}

/// Moves one save into the new copy. Whatever is there came with the archive: it's kept aside.
fn move_save(from: &Path, to: &Path) -> io::Result<()> {
    if let Some(d) = to.parent() {
        fs::create_dir_all(d)?;
    }
    if to.exists() {
        let mut aside = to.as_os_str().to_owned();
        aside.push(".from-archive");
        let _ = fs::remove_dir_all(&aside);
        fs::rename(to, &aside)?;
    }
    fs::rename(from, to)
}

/// Carries the player's saves from a game's old copy over to its new one. It can run again
/// over what a run that died left behind: whatever has moved is no longer in `old`.
pub fn keep_saves(old: &Path, new: &Path) -> Result<(), String> {
    let moves = save_moves(old, new).map_err(|e| format!("keeping saves {}: {}", old.display(), e))?;
    for (i, (from, to)) in moves.iter().enumerate() {
        if let Err(e) = move_save(from, to) {
            // the new copy may be about to be thrown away: saves mustn't stay in it
            for (from, to) in &moves[..i] {
                let _ = fs::rename(to, from);
            }
            return Err(format!("keeping saves {}: {}", from.display(), e));
        }
    }
    Ok(())
}

/// Moves the game found in `tmp` to `games/name`, and carries over the player's saves if
/// the game was there before. Only touches the old copy once the new one is in place,
/// and `.old-` folders are what `recover_imports` looks for if the app dies halfway.
#[cfg(any(target_os = "android", test))]
pub fn finish_import(tmp: &Path, games: &Path, name: &str) -> Result<(), String> {
    let game = find_game(tmp).ok_or("no game here: expected a folder holding CSV and ERB folders")?;
    let dest = games.join(name);
    let old = games.join(format!(".old-{}", name));
    let had_old = dest.exists();
    if had_old {
        // a failed import may have left saves here: they go forward before this is deleted
        if old.exists() {
            keep_saves(&old, &dest)?;
        }
        let _ = fs::remove_dir_all(&old);
        fs::rename(&dest, &old).map_err(|e| e.to_string())?;
    }
    if let Err(e) = fs::rename(&game, &dest) {
        if had_old {
            let _ = fs::rename(&old, &dest);
        }
        return Err(e.to_string());
    }
    if had_old {
        keep_saves(&old, &dest)?;
        let _ = fs::remove_dir_all(&old);
    }
    let _ = fs::remove_dir_all(tmp);
    Ok(())
}

/// Cleans up after an import the app didn't live through. Nothing here may lose saves: an
/// `.old-` folder may hold the only copy, so it goes away only once they're safe.
#[cfg(any(target_os = "android", test))]
pub fn recover_imports(games: &Path) {
    let Ok(rd) = fs::read_dir(games) else { return };
    for e in rd.flatten() {
        let n = e.file_name().to_string_lossy().to_string();
        if n.starts_with(".import-") {
            let _ = fs::remove_dir_all(e.path());
        } else if let Some(name) = n.strip_prefix(".old-") {
            let dest = games.join(name);
            if !dest.exists() {
                // died between the two renames: the old game is still the game
                let _ = fs::rename(e.path(), &dest);
            } else if keep_saves(&e.path(), &dest).is_ok() {
                let _ = fs::remove_dir_all(e.path());
            }
        }
    }
}

/// Decode an entry name: UTF-8, else Shift_JIS.
fn decode_name(raw: &[u8]) -> String {
    match std::str::from_utf8(raw) {
        Ok(s) => s.to_string(),
        Err(_) => encoding_rs::SHIFT_JIS.decode(raw).0.into_owned(),
    }
}

/// `root` + an archive entry path, or None if the entry would land outside
/// `root` (absolute path, `..`, Windows drive).
fn safe_join(root: &Path, name: &str) -> Option<PathBuf> {
    let rel = PathBuf::from(name.replace('\\', "/"));
    let mut out = root.to_path_buf();
    let mut any = false;
    for c in rel.components() {
        match c {
            Component::Normal(p) if !p.to_string_lossy().contains(':') => {
                out.push(p);
                any = true;
            }
            Component::CurDir => {}
            _ => return None,
        }
    }
    any.then_some(out)
}

/// Write one regular file from an archive entry.
fn write_file(path: &Path, r: &mut dyn io::Read) -> Result<(), String> {
    if let Some(d) = path.parent() {
        fs::create_dir_all(d).map_err(|e| format!("{}: {}", d.display(), e))?;
    }
    let mut f = fs::File::create(path).map_err(|e| format!("{}: {}", path.display(), e))?;
    io::copy(r, &mut f).map_err(|e| format!("{}: {}", path.display(), e))?;
    Ok(())
}

fn unpack(archive: &Path, to: &Path, progress: &mut dyn FnMut(usize)) -> Result<(), String> {
    let open = || fs::File::open(archive).map_err(|e| format!("{}: {}", archive.display(), e));
    match suffix(archive) {
        Some(".zip") => unzip(open()?, to, progress),
        Some(".tar") => untar(io::BufReader::new(open()?), to, progress),
        Some(".tar.gz") | Some(".tgz") => untar(flate2::read::MultiGzDecoder::new(io::BufReader::new(open()?)), to, progress),
        _ => external(archive, to),
    }
}

/// Unpacks an already opened archive of a type read in-process (`suffix` as from
/// [`suffix`]): the Android app gets a file descriptor from the system, not a path.
pub fn unpack_file(f: fs::File, suffix: &str, to: &Path, progress: &mut dyn FnMut(usize)) -> Result<(), String> {
    match suffix {
        ".zip" => unzip(f, to, progress),
        ".tar" => untar(io::BufReader::new(f), to, progress),
        ".tar.gz" | ".tgz" => untar(flate2::read::MultiGzDecoder::new(io::BufReader::new(f)), to, progress),
        other => Err(format!("{} archives can't be read here", other)),
    }
}

fn unzip(f: fs::File, to: &Path, progress: &mut dyn FnMut(usize)) -> Result<(), String> {
    let mut z = zip::ZipArchive::new(f).map_err(|e| t!("not a readable zip: {error}", error = e))?;
    let mut n = 0;
    for i in 0..z.len() {
        let mut e = z.by_index(i).map_err(|e| format!("zip entry {}: {}", i, e))?;
        let Some(path) = safe_join(to, &decode_name(e.name_raw())) else { continue };
        let is_link = e.unix_mode().is_some_and(|m| m & 0o170000 == 0o120000);
        if e.is_dir() {
            fs::create_dir_all(&path).map_err(|e| format!("{}: {}", path.display(), e))?;
        } else if !is_link {
            write_file(&path, &mut e)?;
            n += 1;
            if n % 200 == 0 {
                progress(n);
            }
        }
    }
    progress(n);
    Ok(())
}

fn untar(r: impl io::Read, to: &Path, progress: &mut dyn FnMut(usize)) -> Result<(), String> {
    let mut a = tar::Archive::new(r);
    let mut n = 0;
    for e in a.entries().map_err(|e| t!("not a readable tar: {error}", error = e))? {
        let mut e = e.map_err(|e| format!("tar: {}", e))?;
        let name = decode_name(&e.path_bytes());
        let Some(path) = safe_join(to, &name) else { continue };
        let kind = e.header().entry_type();
        if kind.is_dir() {
            fs::create_dir_all(&path).map_err(|e| format!("{}: {}", path.display(), e))?;
        } else if kind.is_file() {
            write_file(&path, &mut e)?;
            n += 1;
            if n % 200 == 0 {
                progress(n);
            }
        }
    }
    progress(n);
    Ok(())
}

/// Formats we don't decode ourselves: the first available system tool.
fn external(archive: &Path, to: &Path) -> Result<(), String> {
    use std::process::{Command, Stdio};
    let have = |t: &str| std::env::var_os("PATH").is_some_and(|p| std::env::split_paths(&p).any(|d| d.join(t).is_file()));
    let is_tar = matches!(suffix(archive), Some(".tar.xz" | ".txz" | ".tar.bz2" | ".tbz2" | ".tar.zst"));
    let mut cmd = if have("bsdtar") {
        let mut c = Command::new("bsdtar");
        c.arg("-xf").arg(archive).arg("-C").arg(to);
        c
    } else if is_tar && have("tar") {
        let mut c = Command::new("tar");
        c.arg("-xf").arg(archive).arg("-C").arg(to).arg("--no-same-owner");
        c
    } else if let Some(t) = ["7z", "7za", "7zz"].into_iter().find(|t| have(t)) {
        let mut c = Command::new(t);
        c.arg("x").arg("-y").arg(format!("-o{}", to.display())).arg(archive);
        c
    } else {
        return Err(t!("this archive type needs bsdtar, tar or 7z installed (e.g. `sudo apt install libarchive-tools p7zip-full`)"));
    };
    let st = cmd.stdout(Stdio::null()).stderr(Stdio::null()).status().map_err(|e| e.to_string())?;
    if !st.success() {
        return Err(t!("extracting {archive} failed ({status})", archive = archive.display(), status = st));
    }
    remove_symlinks(to);
    Ok(())
}

/// Delete every symlink under `d` (external tools may create them).
fn remove_symlinks(d: &Path) {
    let Ok(rd) = fs::read_dir(d) else { return };
    for e in rd.flatten() {
        let p = e.path();
        if p.is_symlink() {
            let _ = fs::remove_file(&p);
        } else if p.is_dir() {
            remove_symlinks(&p);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safe_join_blocks_escapes() {
        let r = Path::new("/x");
        assert_eq!(safe_join(r, "a/b.txt"), Some(PathBuf::from("/x/a/b.txt")));
        assert_eq!(safe_join(r, "a\\b.txt"), Some(PathBuf::from("/x/a/b.txt")));
        assert_eq!(safe_join(r, "./a"), Some(PathBuf::from("/x/a")));
        assert_eq!(safe_join(r, "../evil"), None);
        assert_eq!(safe_join(r, "a/../../evil"), None);
        assert_eq!(safe_join(r, "/etc/passwd"), None);
        assert_eq!(safe_join(r, "C:/evil"), None);
        assert_eq!(safe_join(r, ""), None);
    }

    #[test]
    fn suffixes() {
        assert_eq!(suffix(Path::new("Game v1.2.tar.gz")), Some(".tar.gz"));
        assert_eq!(suffix(Path::new("x.TGZ")), Some(".tgz"));
        assert_eq!(suffix(Path::new("x.zip")), Some(".zip"));
        assert_eq!(suffix(Path::new("x.txt")), None);
    }

    #[test]
    fn sjis_names() {
        let (raw, _, _) = encoding_rs::SHIFT_JIS.encode("口上/霊夢.ERB");
        assert_eq!(decode_name(&raw), "口上/霊夢.ERB");
        assert_eq!(decode_name("ok.txt".as_bytes()), "ok.txt");
    }

    fn tmp(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("emuera-archive-{}-{}", tag, std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    fn put(root: &Path, files: &[(&str, &str)]) {
        for (p, text) in files {
            let p = root.join(p);
            fs::create_dir_all(p.parent().unwrap()).unwrap();
            fs::write(p, text).unwrap();
        }
    }

    fn read(root: &Path, p: &str) -> String {
        fs::read_to_string(root.join(p)).unwrap_or_else(|_| format!("{} is missing", p))
    }

    const GAME: &[(&str, &str)] = &[("CSV/A.CSV", ""), ("ERB/A.ERB", "")];

    #[test]
    fn reimport_keeps_saves_outside_the_sav_folder() {
        let d = tmp("root");
        let (games, g, new) = (d.join("games"), d.join("games/g"), d.join("new"));
        let saves = ["save00.sav", "global.sav", "txt00.txt", "img0001.png", "dat/chara_a.dat"];
        put(&g, GAME);
        put(&g, &[("ERB/OLD.ERB", "old"), ("README.txt", "old"), ("dat/schema.xml", "old")]);
        put(&g, &saves.map(|f| (f, "mine")));
        put(&new, GAME);
        put(&new, &[("dat/schema.xml", "new")]);
        finish_import(&new, &games, "g").unwrap();
        for f in saves {
            assert_eq!(read(&g, f), "mine");
        }
        // the old game itself is gone, and the new one's data wins
        assert_eq!(read(&g, "dat/schema.xml"), "new");
        assert!(!g.join("ERB/OLD.ERB").exists());
        assert!(!g.join("README.txt").exists());
        assert!(!games.join(".old-g").exists());
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn saves_that_came_with_the_archive_go_aside() {
        let d = tmp("aside");
        let (games, g, new) = (d.join("games"), d.join("games/g"), d.join("new"));
        let saves = ["sav/save00.sav", "global.sav", "dat/chara_a.dat"];
        put(&g, GAME);
        put(&g, &saves.map(|f| (f, "mine")));
        put(&new, GAME);
        put(&new, &saves.map(|f| (f, "author")));
        finish_import(&new, &games, "g").unwrap();
        for f in saves {
            assert_eq!(read(&g, f), "mine");
        }
        assert_eq!(read(&g, "sav.from-archive/save00.sav"), "author");
        assert_eq!(read(&g, "global.sav.from-archive"), "author");
        assert_eq!(read(&g, "dat/chara_a.dat.from-archive"), "author");
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn dying_midway_loses_nothing() {
        let games = tmp("died");
        // keeping saves stopped halfway
        put(&games.join("g"), GAME);
        put(&games.join("g"), &[("save01.sav", "mine")]);
        put(&games.join(".old-g"), &[("save02.sav", "mine"), ("sav/save03.sav", "mine")]);
        // between the two renames
        put(&games.join(".old-h"), GAME);
        put(&games.join(".old-h"), &[("global.sav", "mine")]);
        put(&games.join(".import-g"), &[("half.txt", "")]);
        recover_imports(&games);
        for f in ["g/save01.sav", "g/save02.sav", "g/sav/save03.sav", "h/global.sav"] {
            assert_eq!(read(&games, f), "mine");
        }
        for leftover in [".old-g", ".old-h", ".import-g"] {
            assert!(!games.join(leftover).exists());
        }
        fs::remove_dir_all(&games).unwrap();
    }

    #[test]
    fn retrying_a_failed_import_keeps_what_it_left() {
        let d = tmp("retry");
        let (games, new) = (d.join("games"), d.join("new"));
        put(&games.join("g"), GAME);
        put(&games.join(".old-g"), &[("global.sav", "mine")]);
        put(&new, GAME);
        finish_import(&new, &games, "g").unwrap();
        assert_eq!(read(&games, "g/global.sav"), "mine");
        assert!(!games.join(".old-g").exists());
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn a_failed_move_puts_saves_back() {
        let d = tmp("failed");
        let (old, new) = (d.join("old"), d.join("new"));
        let saves = ["sav/save00.sav", "global.sav", "dat/chara_a.dat"];
        put(&old, &saves.map(|f| (f, "mine")));
        // a file where the folder for the last save has to go
        put(&new, &[("dat", "")]);
        assert!(keep_saves(&old, &new).is_err());
        for f in saves {
            assert_eq!(read(&old, f), "mine");
        }
        assert!(!new.join("sav").exists());
        assert!(!new.join("global.sav").exists());
        fs::remove_dir_all(&d).unwrap();
    }

    #[test]
    fn root_save_names() {
        for yes in ["save00.sav", "save100.sav", "global.sav", "SAVE00.SAV", "txt00.txt", "img0001.png"] {
            assert!(is_root_save(yes), "{}", yes);
        }
        for no in ["README.txt", "txt.txt", "txtA.txt", "notes.txt", "img.png", "logo.png", "macro.txt"] {
            assert!(!is_root_save(no), "{}", no);
        }
    }
}
