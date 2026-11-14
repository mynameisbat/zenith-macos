// Fixtures for HomebrewTests. `recordedInstalledGh` and `recordedFirefoxCask` are what Homebrew 7.0.13 printed on
// 2026-11-13 (`brew info --json=v2 --installed`, `brew info --json=v2 --cask firefox`; the cask's language list is
// shortened). The other entries are copies of those records with the fields changed that a test needs: a dependency,
// a formula from another tap, an installed and outdated cask. `outdatedSample` follows `brew outdated --json=v2`.
enum HomebrewFixtures {
    static let recordedInstalledGh = #"""
{
  "formulae": [
    {
      "name": "gh",
      "full_name": "gh",
      "tap": "homebrew/core",
      "oldnames": [],
      "aliases": [],
      "versioned_formulae": [],
      "desc": "GitHub command-line tool",
      "license": "MIT",
      "homepage": "https://cli.github.com/",
      "versions": {
        "stable": "2.104.0",
        "head": "HEAD",
        "bottle": true
      },
      "urls": {
        "stable": {
          "url": "https://github.com/cli/cli/archive/refs/tags/v2.104.0.tar.gz",
          "tag": null,
          "revision": null,
          "using": null,
          "checksum": "779060cbdc5a354fa2fc8afb56e9277f64a29ac599daefd941558356509081e4"
        },
        "head": {
          "url": "https://github.com/cli/cli.git",
          "branch": "trunk",
          "using": null
        }
      },
      "patches": [],
      "local_patch_checksums": {},
      "revision": 0,
      "version_scheme": 0,
      "compatibility_version": 1,
      "autobump": true,
      "no_autobump_message": null,
      "skip_livecheck": false,
      "bottle": {
        "stable": {
          "rebuild": 0,
          "root_url": "https://ghcr.io/v2/homebrew/core",
          "files": {
            "arm64_golden_gate": {
              "cellar": ":any_skip_relocation",
              "url": "https://ghcr.io/v2/homebrew/core/gh/blobs/sha256:79a3bd83186260171c42ce1c293b0e908ef5550fb85a0ca7664ae2adb084d4a4",
              "sha256": "79a3bd83186260171c42ce1c293b0e908ef5550fb85a0ca7664ae2adb084d4a4"
            }
          }
        }
      },
      "pour_bottle_only_if": null,
      "keg_only": false,
      "keg_only_reason": null,
      "options": [],
      "build_dependencies": [
        "go"
      ],
      "dependencies": [],
      "test_dependencies": [],
      "recommended_dependencies": [],
      "optional_dependencies": [],
      "no_linkage_dependencies": [],
      "uses_from_macos": [],
      "uses_from_macos_bounds": [],
      "requirements": [],
      "conflicts_with": [],
      "conflicts_with_reasons": [],
      "link_overwrite": [],
      "caveats": null,
      "installed": [
        {
          "sbom": "/opt/homebrew/Cellar/gh/2.104.0/sbom.spdx.json",
          "version": "2.104.0",
          "used_options": [],
          "built_as_bottle": true,
          "poured_from_bottle": true,
          "time": 1794524437,
          "runtime_dependencies": [],
          "installed_on_request": true
        }
      ],
      "linked_keg": "2.104.0",
      "pinned": false,
      "outdated": false,
      "deprecated": false,
      "deprecation_date": null,
      "deprecation_reason": null,
      "deprecation_replacement_formula": null,
      "deprecation_replacement_cask": null,
      "deprecate_args": null,
      "disabled": false,
      "disable_date": null,
      "disable_reason": null,
      "disable_replacement_formula": null,
      "disable_replacement_cask": null,
      "disable_args": null,
      "post_install_steps": [],
      "post_install_defined": false,
      "service": null,
      "tap_git_head": "f3a21c12c0ec4e7873ddbcdb1433802d3d2b409a",
      "ruby_source_path": "Formula/g/gh.rb",
      "ruby_source_checksum": {
        "sha256": "427f59bbb72c53bedfbe9fd7bd07b6ef765896cbc461d889715dfbe09b14d5be"
      }
    }
  ],
  "casks": []
}
"""#

    static let installed = #"""
{
 "formulae": [
  {
   "name": "gh",
   "full_name": "gh",
   "tap": "homebrew/core",
   "oldnames": [],
   "aliases": [],
   "versioned_formulae": [],
   "desc": "GitHub command-line tool",
   "license": "MIT",
   "homepage": "https://cli.github.com/",
   "versions": {
    "stable": "2.104.0",
    "head": "HEAD",
    "bottle": true
   },
   "urls": {
    "stable": {
     "url": "https://github.com/cli/cli/archive/refs/tags/v2.104.0.tar.gz",
     "tag": null,
     "revision": null,
     "using": null,
     "checksum": "779060cbdc5a354fa2fc8afb56e9277f64a29ac599daefd941558356509081e4"
    },
    "head": {
     "url": "https://github.com/cli/cli.git",
     "branch": "trunk",
     "using": null
    }
   },
   "patches": [],
   "local_patch_checksums": {},
   "revision": 0,
   "version_scheme": 0,
   "compatibility_version": 1,
   "autobump": true,
   "no_autobump_message": null,
   "skip_livecheck": false,
   "bottle": {
    "stable": {
     "rebuild": 0,
     "root_url": "https://ghcr.io/v2/homebrew/core",
     "files": {
      "arm64_golden_gate": {
       "cellar": ":any_skip_relocation",
       "url": "https://ghcr.io/v2/homebrew/core/gh/blobs/sha256:79a3bd83186260171c42ce1c293b0e908ef5550fb85a0ca7664ae2adb084d4a4",
       "sha256": "79a3bd83186260171c42ce1c293b0e908ef5550fb85a0ca7664ae2adb084d4a4"
      }
     }
    }
   },
   "pour_bottle_only_if": null,
   "keg_only": false,
   "keg_only_reason": null,
   "options": [],
   "build_dependencies": [
    "go"
   ],
   "dependencies": [],
   "test_dependencies": [],
   "recommended_dependencies": [],
   "optional_dependencies": [],
   "no_linkage_dependencies": [],
   "uses_from_macos": [],
   "uses_from_macos_bounds": [],
   "requirements": [],
   "conflicts_with": [],
   "conflicts_with_reasons": [],
   "link_overwrite": [],
   "caveats": null,
   "installed": [
    {
     "sbom": "/opt/homebrew/Cellar/gh/2.104.0/sbom.spdx.json",
     "version": "2.104.0",
     "used_options": [],
     "built_as_bottle": true,
     "poured_from_bottle": true,
     "time": 1794524437,
     "runtime_dependencies": [],
     "installed_on_request": true
    }
   ],
   "linked_keg": "2.104.0",
   "pinned": false,
   "outdated": false,
   "deprecated": false,
   "deprecation_date": null,
   "deprecation_reason": null,
   "deprecation_replacement_formula": null,
   "deprecation_replacement_cask": null,
   "deprecate_args": null,
   "disabled": false,
   "disable_date": null,
   "disable_reason": null,
   "disable_replacement_formula": null,
   "disable_replacement_cask": null,
   "disable_args": null,
   "post_install_steps": [],
   "post_install_defined": false,
   "service": null,
   "tap_git_head": "f3a21c12c0ec4e7873ddbcdb1433802d3d2b409a",
   "ruby_source_path": "Formula/g/gh.rb",
   "ruby_source_checksum": {
    "sha256": "427f59bbb72c53bedfbe9fd7bd07b6ef765896cbc461d889715dfbe09b14d5be"
   }
  },
  {
   "name": "openssl@3",
   "full_name": "openssl@3",
   "tap": "homebrew/core",
   "oldnames": [],
   "aliases": [],
   "versioned_formulae": [],
   "desc": "Cryptography and SSL/TLS Toolkit",
   "license": "MIT",
   "homepage": "https://openssl-library.org",
   "versions": {
    "stable": "3.6.1",
    "head": null,
    "bottle": true
   },
   "urls": {
    "stable": {
     "url": "https://github.com/cli/cli/archive/refs/tags/v2.104.0.tar.gz",
     "tag": null,
     "revision": null,
     "using": null,
     "checksum": "779060cbdc5a354fa2fc8afb56e9277f64a29ac599daefd941558356509081e4"
    },
    "head": {
     "url": "https://github.com/cli/cli.git",
     "branch": "trunk",
     "using": null
    }
   },
   "patches": [],
   "local_patch_checksums": {},
   "revision": 0,
   "version_scheme": 0,
   "compatibility_version": 1,
   "autobump": true,
   "no_autobump_message": null,
   "skip_livecheck": false,
   "bottle": {
    "stable": {
     "rebuild": 0,
     "root_url": "https://ghcr.io/v2/homebrew/core",
     "files": {
      "arm64_golden_gate": {
       "cellar": ":any_skip_relocation",
       "url": "https://ghcr.io/v2/homebrew/core/gh/blobs/sha256:79a3bd83186260171c42ce1c293b0e908ef5550fb85a0ca7664ae2adb084d4a4",
       "sha256": "79a3bd83186260171c42ce1c293b0e908ef5550fb85a0ca7664ae2adb084d4a4"
      }
     }
    }
   },
   "pour_bottle_only_if": null,
   "keg_only": false,
   "keg_only_reason": null,
   "options": [],
   "build_dependencies": [
    "go"
   ],
   "dependencies": [],
   "test_dependencies": [],
   "recommended_dependencies": [],
   "optional_dependencies": [],
   "no_linkage_dependencies": [],
   "uses_from_macos": [],
   "uses_from_macos_bounds": [],
   "requirements": [],
   "conflicts_with": [],
   "conflicts_with_reasons": [],
   "link_overwrite": [],
   "caveats": null,
   "installed": [
    {
     "version": "3.6.0",
     "used_options": [],
     "built_as_bottle": true,
     "poured_from_bottle": true,
     "time": 1790000000,
     "runtime_dependencies": [],
     "installed_on_request": false
    }
   ],
   "linked_keg": "3.6.0",
   "pinned": false,
   "outdated": true,
   "deprecated": false,
   "deprecation_date": null,
   "deprecation_reason": null,
   "deprecation_replacement_formula": null,
   "deprecation_replacement_cask": null,
   "deprecate_args": null,
   "disabled": false,
   "disable_date": null,
   "disable_reason": null,
   "disable_replacement_formula": null,
   "disable_replacement_cask": null,
   "disable_args": null,
   "post_install_steps": [],
   "post_install_defined": false,
   "service": null,
   "tap_git_head": "f3a21c12c0ec4e7873ddbcdb1433802d3d2b409a",
   "ruby_source_path": "Formula/g/gh.rb",
   "ruby_source_checksum": {
    "sha256": "427f59bbb72c53bedfbe9fd7bd07b6ef765896cbc461d889715dfbe09b14d5be"
   }
  },
  {
   "name": "tool",
   "full_name": "someone/tap/tool",
   "tap": "someone/tap",
   "oldnames": [],
   "aliases": [],
   "versioned_formulae": [],
   "desc": null,
   "license": "MIT",
   "homepage": "https://cli.github.com/",
   "versions": {
    "stable": "2.104.0",
    "head": "HEAD",
    "bottle": true
   },
   "urls": {
    "stable": {
     "url": "https://github.com/cli/cli/archive/refs/tags/v2.104.0.tar.gz",
     "tag": null,
     "revision": null,
     "using": null,
     "checksum": "779060cbdc5a354fa2fc8afb56e9277f64a29ac599daefd941558356509081e4"
    },
    "head": {
     "url": "https://github.com/cli/cli.git",
     "branch": "trunk",
     "using": null
    }
   },
   "patches": [],
   "local_patch_checksums": {},
   "revision": 0,
   "version_scheme": 0,
   "compatibility_version": 1,
   "autobump": true,
   "no_autobump_message": null,
   "skip_livecheck": false,
   "bottle": {
    "stable": {
     "rebuild": 0,
     "root_url": "https://ghcr.io/v2/homebrew/core",
     "files": {
      "arm64_golden_gate": {
       "cellar": ":any_skip_relocation",
       "url": "https://ghcr.io/v2/homebrew/core/gh/blobs/sha256:79a3bd83186260171c42ce1c293b0e908ef5550fb85a0ca7664ae2adb084d4a4",
       "sha256": "79a3bd83186260171c42ce1c293b0e908ef5550fb85a0ca7664ae2adb084d4a4"
      }
     }
    }
   },
   "pour_bottle_only_if": null,
   "keg_only": false,
   "keg_only_reason": null,
   "options": [],
   "build_dependencies": [
    "go"
   ],
   "dependencies": [],
   "test_dependencies": [],
   "recommended_dependencies": [],
   "optional_dependencies": [],
   "no_linkage_dependencies": [],
   "uses_from_macos": [],
   "uses_from_macos_bounds": [],
   "requirements": [],
   "conflicts_with": [],
   "conflicts_with_reasons": [],
   "link_overwrite": [],
   "caveats": null,
   "installed": [
    {
     "version": "1.0",
     "installed_on_request": true
    }
   ],
   "linked_keg": "2.104.0",
   "pinned": true,
   "outdated": false,
   "deprecated": false,
   "deprecation_date": null,
   "deprecation_reason": null,
   "deprecation_replacement_formula": null,
   "deprecation_replacement_cask": null,
   "deprecate_args": null,
   "disabled": false,
   "disable_date": null,
   "disable_reason": null,
   "disable_replacement_formula": null,
   "disable_replacement_cask": null,
   "disable_args": null,
   "post_install_steps": [],
   "post_install_defined": false,
   "service": null,
   "tap_git_head": "f3a21c12c0ec4e7873ddbcdb1433802d3d2b409a",
   "ruby_source_path": "Formula/g/gh.rb",
   "ruby_source_checksum": {
    "sha256": "427f59bbb72c53bedfbe9fd7bd07b6ef765896cbc461d889715dfbe09b14d5be"
   }
  }
 ],
 "casks": [
  {
   "token": "firefox",
   "full_token": "firefox",
   "old_tokens": [],
   "tap": "homebrew/cask",
   "name": [
    "Mozilla Firefox"
   ],
   "desc": "Web browser",
   "homepage": "https://www.mozilla.org/firefox/",
   "url": "https://download-installer.cdn.mozilla.net/pub/firefox/releases/160.0/mac/en-US/Firefox%20160.0.dmg",
   "url_specs": {},
   "version": "160.0",
   "autobump": true,
   "no_autobump_message": null,
   "skip_livecheck": false,
   "installed": "159.0",
   "installed_time": 1790000000,
   "bundle_version": null,
   "bundle_short_version": null,
   "pinned": false,
   "pinned_version": null,
   "outdated": true,
   "sha256": "b270ccc60eb899bd0277bd078d7bd8690f5c4fc3e44b4fa9ee78ed2a3e89f0ca",
   "artifacts": [
    {
     "uninstall": [
      {
       "quit": "org.mozilla.firefox"
      }
     ]
    },
    {
     "app": [
      "Firefox.app"
     ],
     "target": "/Applications/Firefox.app"
    },
    {
     "command_wrapper": [
      "firefox",
      {
       "executable": "/Applications/Firefox.app/Contents/MacOS/firefox"
      }
     ],
     "target": "/opt/homebrew/bin/firefox"
    },
    {
     "zap": [
      {
       "trash": [
        "/Library/Logs/DiagnosticReports/firefox_*",
        "~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/org.mozilla.firefox.sfl*",
        "~/Library/Application Support/CrashReporter/firefox_*",
        "~/Library/Application Support/Firefox",
        "~/Library/Caches/Firefox",
        "~/Library/Caches/Mozilla/updates/Applications/Firefox",
        "~/Library/Caches/org.mozilla.crashreporter",
        "~/Library/Caches/org.mozilla.firefox",
        "~/Library/Preferences/org.mozilla.crashreporter.plist",
        "~/Library/Preferences/org.mozilla.firefox.plist",
        "~/Library/Saved Application State/org.mozilla.firefox.savedState",
        "~/Library/WebKit/org.mozilla.firefox"
       ],
       "rmdir": [
        "~/Library/Application Support/Mozilla",
        "~/Library/Caches/Mozilla",
        "~/Library/Caches/Mozilla/updates",
        "~/Library/Caches/Mozilla/updates/Applications"
       ]
      }
     ]
    }
   ],
   "caveats": null,
   "caveats_rosetta": null,
   "depends_on": {
    "macos": {}
   },
   "conflicts_with": {
    "cask": [
     "firefox@beta",
     "firefox@cn",
     "firefox@esr"
    ]
   },
   "container": null,
   "rename": [],
   "auto_updates": true,
   "deprecated": false,
   "deprecation_date": null,
   "deprecation_reason": null,
   "deprecation_replacement_formula": null,
   "deprecation_replacement_cask": null,
   "deprecate_args": null,
   "disabled": false,
   "disable_date": null,
   "disable_reason": null,
   "disable_replacement_formula": null,
   "disable_replacement_cask": null,
   "disable_args": null,
   "tap_git_head": "7397801fbe3ada511d5ac422b78730f4735af8f9",
   "languages": [
    "ach",
    "af",
    "an"
   ],
   "ruby_source_path": "Casks/f/firefox.rb",
   "ruby_source_checksum": {
    "sha256": "3776eb400944b953b6a6020c441cc72531f4576331615bb2d8693659b1afb914"
   }
  }
 ]
}
"""#

    static let recordedFirefoxCask = #"""
{
 "formulae": [],
 "casks": [
  {
   "token": "firefox",
   "full_token": "firefox",
   "old_tokens": [],
   "tap": "homebrew/cask",
   "name": [
    "Mozilla Firefox"
   ],
   "desc": "Web browser",
   "homepage": "https://www.mozilla.org/firefox/",
   "url": "https://download-installer.cdn.mozilla.net/pub/firefox/releases/160.0/mac/en-US/Firefox%20160.0.dmg",
   "url_specs": {},
   "version": "160.0",
   "autobump": true,
   "no_autobump_message": null,
   "skip_livecheck": false,
   "installed": null,
   "installed_time": null,
   "bundle_version": null,
   "bundle_short_version": null,
   "pinned": false,
   "pinned_version": null,
   "outdated": false,
   "sha256": "b270ccc60eb899bd0277bd078d7bd8690f5c4fc3e44b4fa9ee78ed2a3e89f0ca",
   "artifacts": [
    {
     "uninstall": [
      {
       "quit": "org.mozilla.firefox"
      }
     ]
    },
    {
     "app": [
      "Firefox.app"
     ],
     "target": "/Applications/Firefox.app"
    },
    {
     "command_wrapper": [
      "firefox",
      {
       "executable": "/Applications/Firefox.app/Contents/MacOS/firefox"
      }
     ],
     "target": "/opt/homebrew/bin/firefox"
    },
    {
     "zap": [
      {
       "trash": [
        "/Library/Logs/DiagnosticReports/firefox_*",
        "~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/org.mozilla.firefox.sfl*",
        "~/Library/Application Support/CrashReporter/firefox_*",
        "~/Library/Application Support/Firefox",
        "~/Library/Caches/Firefox",
        "~/Library/Caches/Mozilla/updates/Applications/Firefox",
        "~/Library/Caches/org.mozilla.crashreporter",
        "~/Library/Caches/org.mozilla.firefox",
        "~/Library/Preferences/org.mozilla.crashreporter.plist",
        "~/Library/Preferences/org.mozilla.firefox.plist",
        "~/Library/Saved Application State/org.mozilla.firefox.savedState",
        "~/Library/WebKit/org.mozilla.firefox"
       ],
       "rmdir": [
        "~/Library/Application Support/Mozilla",
        "~/Library/Caches/Mozilla",
        "~/Library/Caches/Mozilla/updates",
        "~/Library/Caches/Mozilla/updates/Applications"
       ]
      }
     ]
    }
   ],
   "caveats": null,
   "caveats_rosetta": null,
   "depends_on": {
    "macos": {}
   },
   "conflicts_with": {
    "cask": [
     "firefox@beta",
     "firefox@cn",
     "firefox@esr"
    ]
   },
   "container": null,
   "rename": [],
   "auto_updates": true,
   "deprecated": false,
   "deprecation_date": null,
   "deprecation_reason": null,
   "deprecation_replacement_formula": null,
   "deprecation_replacement_cask": null,
   "deprecate_args": null,
   "disabled": false,
   "disable_date": null,
   "disable_reason": null,
   "disable_replacement_formula": null,
   "disable_replacement_cask": null,
   "disable_args": null,
   "tap_git_head": "7397801fbe3ada511d5ac422b78730f4735af8f9",
   "languages": [
    "ach",
    "af",
    "an"
   ],
   "ruby_source_path": "Casks/f/firefox.rb",
   "ruby_source_checksum": {
    "sha256": "3776eb400944b953b6a6020c441cc72531f4576331615bb2d8693659b1afb914"
   }
  }
 ]
}
"""#

    static let outdatedSample = #"""
{
  "formulae": [
    {
      "name": "openssl@3",
      "installed_versions": ["3.6.0"],
      "current_version": "3.6.1",
      "pinned": false,
      "pinned_version": null
    },
    {
      "name": "node",
      "installed_versions": ["22.1.0", "23.0.0"],
      "current_version": "25.2.1",
      "pinned": true,
      "pinned_version": "23.0.0"
    }
  ],
  "casks": [
    {
      "name": "firefox",
      "installed_versions": ["159.0"],
      "current_version": "160.0"
    }
  ]
}
"""#

    static let recordedOutdatedEmpty = #"""
{
  "formulae": [],
  "casks": []
}
"""#

    /// `brew search --cask fire` as recorded (piped, so no headers).
    static let recordedCaskSearch = """
firealpaca
firebase-admin
firebird-emu
firecamp
firefly-iota-desktop
firefly-shimmer
firefox
firefox@beta
firefox@cn
firefox@developer-edition
firefox@esr
firefox@nightly
firestorm
fireworks
firezone
font-palemonasmufi-regular
spitfire-audio
"""
}
