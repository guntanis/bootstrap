# Bootstrap Script

A comprehensive bootstrap script to quickly set up a new Linux/macOS system with essential configurations.

## Features

This script automates the setup of:

1. **History Search with Arrow Keys**
   - Configures shell history search using Up/Down arrow keys
   - Works with both `zsh` and `bash`
   - Enables history sharing and deduplication

2. **SSH Public Key Setup**
   - Creates `~/.ssh` directory if it doesn't exist
   - Adds your SSH public key to `~/.ssh/authorized_keys`
   - Sets proper permissions (700 for directory, 600 for authorized_keys)

3. **Default Editor Configuration** (Debian/Ubuntu only)
   - Sets `vim` as the default system editor using `update-alternatives`
   - Configures `EDITOR` and `VISUAL` environment variables

4. **Passwordless Sudo** (Debian/Ubuntu only)
   - Configures passwordless sudo for users in the `sudo` group
   - Creates `/etc/sudoers.d/99-passwordless-sudo` with proper permissions

## Usage

### Run from GitHub

```bash
curl -fsSL https://raw.githubusercontent.com/guntanis/bootstrap/main/bootstrap.sh | bash
```


### Run Locally

```bash
./bootstrap.sh
```

Or from anywhere:

```bash
/path/to/bootstrap/bootstrap.sh
```

## Requirements

- `bash` shell
- For Debian/Ubuntu features: `sudo` access (for editor and passwordless sudo setup)
- For SSH key setup: write access to `~/.ssh/` directory

## What Gets Modified

- `~/.zshrc` or `~/.bashrc` / `~/.bash_profile` - Shell configuration
- `~/.ssh/authorized_keys` - SSH authorized keys
- `/etc/sudoers.d/99-passwordless-sudo` - Sudo configuration (Debian/Ubuntu, requires sudo)
- System editor via `update-alternatives` (Debian/Ubuntu, requires sudo)

## Safety

- The script is **idempotent** - safe to run multiple times
- Checks for existing configurations before modifying
- Uses `set -e` to exit on errors
- Only modifies system files when running as root or with sudo

## After Running

1. Restart your terminal or run:
   ```bash
   source ~/.zshrc  # or ~/.bashrc
   ```

2. Test history search by typing a command and pressing Up/Down arrows

3. Your SSH key is ready to use for authentication

## Platform Support

- **macOS**: History search, SSH key setup
- **Debian/Ubuntu**: All features
- **Other Linux**: History search, SSH key setup (editor and sudo features skipped)

## License

This script is provided as-is for personal use.

