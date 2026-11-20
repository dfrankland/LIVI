// SPDX-FileCopyrightText: 2025-2026 Lasse Heitgres
// SPDX-License-Identifier: GPL-3.0-or-later
// Additional terms: see NOTICE

/// Directories searched for system tools before falling back to `PATH`. The
/// last two are the NixOS system profile, which has no `/usr/bin` or `/sbin`.
const TOOL_DIRS: [&str; 6] = [
    "/usr/sbin",
    "/sbin",
    "/usr/bin",
    "/bin",
    "/run/current-system/sw/sbin",
    "/run/current-system/sw/bin",
];

/// True when the host's package manager owns LIVI's system integration (udev
/// rule, sudoers, systemd units, helper copies), e.g. the NixOS module. LIVI then
/// uses what is there and never installs or rewrites any of it.
pub fn system_managed() -> bool {
    std::env::var_os("LIVI_SYSTEM_MANAGED").is_some_and(|v| !v.is_empty() && v != "0")
}

pub fn tool(name: &str) -> String {
    for dir in TOOL_DIRS {
        let path = format!("{dir}/{name}");
        if std::path::Path::new(&path).exists() {
            return path;
        }
    }
    name.to_string()
}

#[cfg(test)]
mod tests {
    use super::tool;

    #[test]
    fn a_program_that_is_there_comes_back_with_its_directory() {
        let sh = tool("sh");
        assert!(sh.starts_with('/') && sh.ends_with("/sh"), "{sh}");
    }

    #[test]
    fn an_unknown_program_stays_as_it_was() {
        assert_eq!(tool("livi-no-such-program"), "livi-no-such-program");
    }
}
