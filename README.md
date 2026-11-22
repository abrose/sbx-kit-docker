# sbx-kit-docker

A schema 3 mixin layer of sbx-stack. It lets a sandbox on the base image `sbx-stack-base` pull Docker Hub images
through one pull-through mirror on the Mac. Docker, Docker Compose and Testcontainers already run in every sbx
sandbox; the kit adds the mirror, the network rules for Docker Hub, a disk warning, and instructions for the agent.

## What it does

- **On the Mac:** `host/sbx-docker-mirror` runs the container `sbx-docker-mirror` (`registry:3` in proxy mode for
  Docker Hub) on `127.0.0.1:29500`. One mirror serves every sandbox, project and sbx instance of the Mac. It keeps a
  blob for 7 days after its last pull.
- **In the sandbox:** a startup hook sets `registry-mirrors` to `http://host.docker.internal:<port>` in
  `/etc/docker/daemon.json` and reloads `dockerd`. It keeps every other key of the file. It writes the file only when
  the mirror changes, never deletes it, and leaves an invalid file as it is.
- **Fallback:** when the mirror is down, `dockerd` pulls from Docker Hub directly.
- **Disk:** the hook warns in `/var/log/sbx-docker.log` when `/var/lib/docker` is more than 80 % full.
- **Agent context:** the agent learns where images come from, what a 403 of the proxy means, and when to check the
  disk.

A cold pull of `postgres:16-alpine` took 14 s through the mirror, a warm one 2 s (2026-11-20).

## Set up

1. Give the instance an image disk of 25 GB. The file on the Mac is sparse: it costs only what the images fill, and
   `sbx env rm` deletes it.

   ```bash
   sbx settings set sandbox.disk.dockerVolume 25g
   ```

   With `sbx-instances`: `sbx-instance run <instance> -- settings set sandbox.disk.dockerVolume 25g`. One sandbox can
   take another size from `DOCKER_SANDBOXES_DOCKER_SIZE` at its create.

2. Start the mirror once on each Mac. Docker Desktop must run.

   ```bash
   host/sbx-docker-mirror up
   ```

3. Add the kit to the project file:

   ```yaml
   # sbxenv.yaml of a project
   kits:
     - docker.io/docker/sbx-kit-claude:latest
     - git+https://github.com/OWNER/sbx-kit-docker.git#ref=<40-hex sha>
   sandboxOptions:
     template: sbx-stack-base:0
     pullPolicy: never
     skills: "off"
   ```

   - A git source needs the sbx user setting `kit.allowedSources` to allow it.
   - A project file can repair a stopped mirror at each task start. The `|| true` keeps a sandbox start from failing
     when Docker Desktop does not run:

     ```yaml
     lifecycle:
       initialize:
         - command: /path/to/sbx-kit-docker/host/sbx-docker-mirror up || true
     ```

4. Allow the other registries of the project (`quay.io`, `ghcr.io`, a private registry) and the hosts that its
   containers fetch data from at start, in the project file.

## The mirror script

```text
host/sbx-docker-mirror [--name <name>] [--port <port>] up|status|down|purge
```

| Command | What it does |
|---|---|
| `up` | Starts the mirror when it does not run. Does nothing when it runs on the same port. Fails when it runs on another port, or when another process holds the port. Never recreates a running mirror |
| `status` | `running 127.0.0.1:<port>, cache <size>`, `stopped`, or `absent` |
| `down` | Removes the container, keeps the cache volume |
| `purge` | `down`, then removes the cache volume |

Exit codes: 0 done, 1 failed, 2 usage. `--name` sets the name of the container and of its volume (default
`sbx-docker-mirror`); only the tests use another name.

## Args

| Arg | Default | What |
|---|---|---|
| `mirrorPort` | `29500` | The loopback port of the mirror on the Mac. Pass the same value to `--port` of the script |

## Network rules

| Phase | Host | Methods |
|---|---|---|
| runtime | `registry-1.docker.io`, `auth.docker.io`, `production.cloudfront.docker.com`, `production.cloudflare.docker.com` | `GET`, `HEAD`: pulls work, a push gets 403 |
| runtime | `localhost:<mirrorPort>`: the Mac's loopback port, reached at `host.docker.internal:<mirrorPort>` | all |

## Limits

- Only Docker Hub images use the cache. Images of other registries pull directly in each new task.
- A new sandbox starts with an empty image store: `sbx template save` does not keep `/var/lib/docker`. A warm pull
  of all images of a project still takes some seconds per image.
- A container that fetches data at start (for example a virus scanner's signatures) fetches it in each new task.
- The mirror serves every public Docker Hub image to every sandbox of the Mac with the mirror rule. This is the same
  reach as the direct rules.
- The mirror pulls anonymously. It pulls each image once per cache period, so the anonymous limits of Docker Hub
  matter little.
- `sbx env rm` leaves some volume files of a sandbox behind on the Mac (`sandbox-volume-*.img`, about 35 MB per
  removed sandbox, seen with sbx v0.54.0). The Docker volume is not among them. This is sbx behaviour, not the kit's.

## Check

```bash
bash tests/mirror.sh
sbx kit validate .
bash tests/check.sh
```

- `tests/mirror.sh` runs on the Mac only. It tests the script with its own mirror `sbx-docker-mirror-test` on port
  29598, and removes it. It takes about 1 minute.
- `tests/check.sh` starts its own mirror `sbx-docker-mirror-check` on port 29599, creates the sandbox `check-docker`
  from `tests/sbxenv.yaml` on the base image `sbx-stack-base`, asserts in the sandbox and on the Mac, and removes
  both. Run `build.sh` in `sbx-stack-base` first. It takes about 3 minutes.
- Neither test touches the mirror `sbx-docker-mirror`, so both are safe while tasks run.

## License

MIT, see `LICENSE`.
