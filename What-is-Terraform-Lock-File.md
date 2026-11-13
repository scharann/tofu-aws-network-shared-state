# Understanding `.terraform.lock.hcl` (Dependency Lock File)

## 1. What is `.terraform.lock.hcl`?
`.terraform.lock.hcl` is OpenTofu's (and Terraform's) **dependency lock file**. Whenever you run `tofu init` in a directory containing `.tf` configuration files, OpenTofu automatically generates or updates this HCL-formatted file in the root of your repository.

It records two critical pieces of metadata for every external provider (such as `registry.opentofu.org/hashicorp/aws`) required by your configuration:
1. **Exact Selected Version:** The exact version number installed (e.g., `version = "5.100.0"`), along with the original version constraint from your `.tf` files (e.g., `constraints = "~> 5.0"`).
2. **Cryptographic Checksums (`hashes`):** SHA-256 hashes (`h1:` and `zh:` digests) of the official provider release packages so OpenTofu can verify binary integrity on future runs.

---

## 2. Why Should `.terraform.lock.hcl` Be Pushed to Your Git Repository?
Version-controlling `.terraform.lock.hcl` is an official OpenTofu/Terraform best practice (identical to committing `package-lock.json` in Node.js, `go.sum` in Go, or `Pipfile.lock` in Python):

- **Shared Team & CI/CD Consistency:** Every engineer cloning the repository and every automated CI/CD runner (GitHub Actions, GitLab CI) reads the exact same lock file and installs the identical provider version.
- **Explicit, Auditable Upgrades:** Provider upgrades only happen when someone intentionally runs `tofu init -upgrade`, creating a clear Git diff in `.terraform.lock.hcl` that can be reviewed in a Pull Request before hitting production.
- **Separation from Heavy Binaries:** While the `.terraform/` folder (which stores gigabytes of compiled provider binaries) belongs in `.gitignore`, `.terraform.lock.hcl` is a lightweight plain-text file (~1–3 KB) designed specifically to live in Git.

---

## 3. Advantages of Committing `.terraform.lock.hcl`
- **100% Deterministic Builds:** Running `tofu init` today, next month, or on a brand-new laptop installs the exact same provider binary down to the byte.
- **Supply-Chain Tamper Protection:** If a provider registry mirror or network proxy serves a modified or corrupted binary, `tofu init` immediately halts with a checksum mismatch error instead of executing untrusted code against your AWS account.
- **Faster Onboarding & Troubleshooting:** Eliminates *"it works on my machine"* discrepancies caused by two developers having slightly different minor or patch versions of the AWS provider installed.

---

## 4. What Problems Does It Solve?
| Problem Without a Lock File | How `.terraform.lock.hcl` Solves It |
| :--- | :--- |
| **Silent Provider Drift:** Writing `version = "~> 5.0"` allows `5.80.0` today and `5.105.0` next week—potentially introducing new default behaviors, deprecations, or provider bugs mid-project. | Locks every clone to `5.80.0` until you explicitly run `tofu init -upgrade`. |
| **State Schema Incompatibility:** A newer provider version may upgrade resource state schemas in S3, preventing teammates still on an older local provider version from running `tofu plan`. | Guarantees every developer and CI runner interacts with the S3 state file using the exact same provider schema version. |
| **Compromised Binary Downloads:** Downloading a binary over the internet without pinning its hash leaves room for corrupted or tampered archives. | Validates every downloaded `.zip` archive against stored `h1:` / `zh:` SHA-256 digests before extracting it into `.terraform/`. |

---

## 5. How Does It Work Under the Hood?
1. **First `tofu init` (No Lock File Yet):**
   - OpenTofu reads `required_providers` in your `.tf` files (e.g., `hashicorp/aws ~> 5.0`).
   - It queries `registry.opentofu.org`, selects the newest version matching `~> 5.0`, downloads the archive for your OS/architecture (e.g., `darwin_arm64`), and writes `.terraform.lock.hcl` with the selected version and SHA-256 hashes.
2. **Subsequent `tofu init` (Lock File Exists in Git):**
   - OpenTofu reads `.terraform.lock.hcl` **first**.
   - Even if a newer `5.x` version has been released on the registry, OpenTofu ignores it and downloads the exact version pinned in `.terraform.lock.hcl`.
   - It hashes the downloaded provider package and compares it against the `hashes` block in `.terraform.lock.hcl`. If the hashes match, initialization succeeds; if not, OpenTofu aborts with an error.
3. **Intentional Upgrades (`tofu init -upgrade`):**
   - Passing `-upgrade` tells OpenTofu to bypass the pinned version in `.terraform.lock.hcl`, fetch the latest version allowed by your `.tf` constraints, and overwrite `.terraform.lock.hcl` with the new version and hashes.

> **Cross-Platform Tip (macOS + Linux CI/CD):** When you run `tofu init` on macOS Apple Silicon (`darwin_arm64`), OpenTofu initially records `h1:` hashes for `darwin_arm64` alongside platform-independent `zh:` registry hashes. If a Linux CI runner (`linux_amd64`) later runs `tofu init -locked=true`, pre-populate multi-platform hashes once using:
> ~~~bash
> tofu providers lock -platform=darwin_arm64 -platform=linux_amd64
> ~~~

---

## 6. What Happens If `.terraform.lock.hcl` Does Not Exist?
If `.terraform.lock.hcl` is missing (or deleted/gitignored) when someone clones the repository and runs `tofu init`:
1. **No Error Occurs—OpenTofu Recreates It:** `tofu init` still succeeds, automatically resolves the newest provider version matching your `.tf` version constraints, and generates a brand-new `.terraform.lock.hcl` locally.
2. **Version Drift Risk:** Because no pinned version existed, the new clone may pull a newer provider release than the one originally used to create the infrastructure—potentially causing unexpected `tofu plan` diffs, deprecation warnings, or state schema upgrades.
3. **Loss of Historical Checksum Verification:** OpenTofu has no prior cryptographic baseline to verify that the newly downloaded provider matches what was originally tested and approved for the repository.
