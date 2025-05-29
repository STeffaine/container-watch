# container-watch

A utility script for automatically updating and managing multiple Docker Compose projects in a monorepo. Each project resides in its own subdirectory with a `docker-compose.yml` file.

## Features

- ✅ Auto-redeploy services when `docker-compose.yml` changes.
- ✅ Only updates services that are already running.
- ✅ `--force-all` option to force pull and restart all currently running services.
- ✅ `--check-images` option to detect image mismatches between running containers and `docker-compose.yml`, and redeploy mismatched services.
- ✅ Git-integrated diff checking (uses `git pull` and compares commits).
- ✅ Color-coded logs for easy readability.

## Project Structure

The monorepo in which you want to run `container-watch` should have the following structure:

```
.
├── project1
│   └── docker-compose.yml
├── project2
│   └── docker-compose.yml
└── project3
    └── docker-compose.yml
```

## Usage

To run `container-watch` in a project, run the following command from the project's root directory with the correct permissions for `docker` and the git repository:

```bash
./container-watch
```

To force a full redeploy of all docker-compose projects that are currently running, run the following command:

```bash
./container-watch --force-all
```

To check for image mismatches between running containers and `docker-compose.yml`, run the following command:

```bash
./container-watch --check-images
```

## Options

- `--force-all`: Force a full redeploy of all docker-compose projects that are currently running.
- `--check-images`: Check for image mismatches between running containers and `docker-compose.yml`.

## Requirements

- Docker
- Git
- Bash

## Limitations

- Only looks one directory deep for `docker-compose.yml` files.
- Only supports `docker-compose.yml` files with a single `docker-compose.yml` file.
- Image mismatch detections assumes standard `docker-compose.yml` formats.

## Contributing

Contributions are welcome! Please open an issue or submit a pull request.

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.
