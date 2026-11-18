//! Tab completion at a game's input (the "Tab completion" setting, off by
//! default): what is typed is completed to a live button's value, found by
//! the start of its value or a word of its label, or to one of Emuera's
//! `@` system commands. Tab again goes on to the next match. Emuera has no
//! such thing; it only fills the input box, so the game sees nothing new.

/// Emuera's system commands (doSystemCommand), as typed at an input.
const SYSTEM_COMMANDS: &[&str] = &["@DEBUG", "@REBOOT", "@CONFIG", "@OUTPUTLOG", "@QUIT", "@EXIT"];

/// The completions of `typed`, best first: button values that start with
/// it, then buttons with a word of their label starting with it (by their
/// value), or `@` commands. Empty input: every button's value.
pub fn candidates(typed: &str, buttons: &[(String, String)]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut add = |v: &str| {
        if !v.is_empty() && !out.iter().any(|o| o == v) {
            out.push(v.to_string());
        }
    };
    let low = typed.to_lowercase();
    if typed.starts_with('@') {
        for c in SYSTEM_COMMANDS {
            if c.to_lowercase().starts_with(&low) {
                add(c);
            }
        }
        return out;
    }
    for (v, _) in buttons {
        if v.to_lowercase().starts_with(&low) {
            add(v);
        }
    }
    if !typed.is_empty() {
        for (v, label) in buttons {
            // (the `[12]` a label starts with is the value again)
            let words = label.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty());
            if words.clone().any(|w| w.to_lowercase().starts_with(&low)) || label.to_lowercase().starts_with(&low) {
                add(v);
            }
        }
    }
    out
}

/// The cycle Tab steps through: the matches for what was typed, and the
/// one shown now.
#[derive(Default)]
pub struct Cycle {
    matches: Vec<String>,
    at: usize,
}

impl Cycle {
    /// Tab with `line` in the box: the text to put there, if any. A box
    /// still holding the last completion goes on to the next match;
    /// anything else starts over from what is typed.
    pub fn next(&mut self, line: &str, buttons: &[(String, String)]) -> Option<String> {
        if self.matches.get(self.at).is_some_and(|m| m == line) && self.matches.len() > 1 {
            self.at = (self.at + 1) % self.matches.len();
        } else {
            self.matches = candidates(line, buttons);
            self.at = 0;
        }
        self.matches.get(self.at).cloned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b(list: &[(&str, &str)]) -> Vec<(String, String)> {
        list.iter().map(|(v, l)| (v.to_string(), l.to_string())).collect()
    }

    #[test]
    fn values_labels_and_commands() {
        let bs = b(&[("100", "[100] - Wake Up"), ("101", "[101] - Abilities"), ("200", "[200] - Save"), ("SORT", "Sort by level")]);
        assert_eq!(candidates("10", &bs), ["100", "101"]);
        assert_eq!(candidates("wa", &bs), ["100"]);
        assert_eq!(candidates("s", &bs), ["SORT", "200"]);
        assert_eq!(candidates("lev", &bs), ["SORT"]);
        assert_eq!(candidates("", &bs), ["100", "101", "200", "SORT"]);
        assert_eq!(candidates("@re", &bs), ["@REBOOT"]);
        assert!(candidates("zzz", &bs).is_empty());
    }

    #[test]
    fn tab_again_cycles() {
        let bs = b(&[("100", "[100] Wake Up"), ("101", "[101] Abilities")]);
        let mut c = Cycle::default();
        assert_eq!(c.next("10", &bs).as_deref(), Some("100"));
        assert_eq!(c.next("100", &bs).as_deref(), Some("101"));
        assert_eq!(c.next("101", &bs).as_deref(), Some("100"));
        // (typing something else starts over)
        assert_eq!(c.next("ab", &bs).as_deref(), Some("101"));
        assert_eq!(c.next("q", &bs), None);
    }
}
