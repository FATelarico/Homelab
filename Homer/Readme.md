# Localise remote Homer assets

This script helps migrate externally hosted dashboard assets (typically icons and similar files) into local storage on a Homer container or LXC.

## Why use it

When testing a Homer dashboard, it is practical to start with external asset URLs in the YAML configuration.

For production use, that is usually not ideal:
- external assets add third-party dependencies
- remote fetches can leak metadata
- performance is worse than serving files locally
- dashboards become dependent on upstream availability

The script scans a Homer YAML file for remote URLs, filters them by `Content-Type`, and downloads the matching files into a local directory.

## What the script does

The script:
- extracts `http://` and `https://` URLs from a YAML file
- probes each URL before downloading it
- skips unwanted content types by default
- can optionally probe in parallel
- downloads the accepted files into a local directory
- can save the final accepted URL list

By default it excludes:
- `text/html`
- `application/xhtml+xml`
- `text/plain`

This is intended to avoid downloading pages instead of assets.

## Typical workflow

1. Copy the script onto the container or LXC running Homer.
2. Run it against your Homer YAML file.
3. Review the downloaded files.
4. Edit the Homer YAML so the icon or asset references point to the new local files.
5. Reload or restart Homer if needed.

## Basic usage

```bash
./download_assets.sh config.yml
````

This scans `config.yml` and downloads accepted assets into:

```text
assets/
```

## Common examples

Download into a specific directory:

```bash
./download_assets.sh -o assets config.yml
```

Save the final accepted URL list:

```bash
./download_assets.sh -s config.yml
```

Allow `text/plain` responses as well:

```bash
./download_assets.sh --include-plain-text config.yml
```

Allow HTML responses too:

```bash
./download_assets.sh --include-html config.yml
```

Use parallel probing:

```bash
./download_assets.sh --parallel-probe --parallel-jobs 8 config.yml
```

Skip files larger than 5 MB:

```bash
./download_assets.sh --max-size-bytes 5000000 config.yml
```

## After downloading

Update the Homer YAML so remote URLs become local paths.

Example:

```yaml
icon: https://example.com/icons/service.svg
```

becomes something like:

```yaml
icon: assets/service.svg
```

Adjust the path to match how your Homer instance serves static files.

## Notes

* If two remote assets have the same filename, one may overwrite the other.
* Some sources use generic filenames and may need manual renaming after download (e.g., generated badge or icon services such as `shields.io`).
* Some servers do not provide reliable `Content-Type` or `Content-Length` headers. Those URLs may be skipped or handled differently than expected.
* The script is a migration aid, not a full asset management system.
