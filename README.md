# leil-container
Experimental container-based deployment cluster for [LeilFS](https://github.com/leil-io/leilfs)

The ultimate goal of this repository is to bring all the advantages of containers into LeilFS project.

## Official Docker Images

LeilFS container images are published on Docker Hub: [leilfs/public](https://hub.docker.com/r/leilfs/public)

**To pull the images:**

```
docker pull leilfs/public:leil-master-<version>-ubuntu-<distro>
docker pull leilfs/public:leil-metalogger-<version>-ubuntu-<distro>
docker pull leilfs/public:leil-cgiserver-<version>-ubuntu-<distro>
docker pull leilfs/public:leil-chunkserver-<version>-ubuntu-<distro>
docker pull leilfs/public:leil-client-<version>-ubuntu-<distro>
```

Replace `<version>` (e.g. `5.9.0-1`) and `<distro>` (e.g. `24.04` or `22.04`) as needed.

Example:

```
docker pull leilfs/public:leil-master-5.9.0-1-ubuntu-24.04
```

## Warning - about testing and educational usage only

This project was created for making fast DEMOs and playground purpose.

**It should NOT be used for production data!**

## Requirements

Project requires `docker` and `docker-compose`

Also some (`1GB`) free space on hdd is recommended for efficient simulation of storage replication.

## Multi-Ubuntu Build & Tagging

This project supports building and running for both Ubuntu 22.04 and 24.04. All images are tagged with both the LeilFS version and the Ubuntu version for clarity (e.g. `leil-master:5.8.0-1-ubuntu-24.04`).

### Build base images for both Ubuntu versions

```sh
# Ubuntu 24.04 (noble)
docker build -t leil-base:ubuntu-24.04 --build-arg BASE_IMAGE=ubuntu:24.04 ./leil-base
# Ubuntu 22.04 (jammy)
docker build -t leil-base:ubuntu-22.04 --build-arg BASE_IMAGE=ubuntu:22.04 ./leil-base
```

### Build and run the full stack for a specific Ubuntu version

```sh
# For Ubuntu 24.04, latest LeilFS version (default)
TAG_SUFFIX=ubuntu-24.04 BASE_IMAGE=leil-base:ubuntu-24.04 docker compose up --build

# For Ubuntu 24.04, pin all components to LeilFS version 5.8.0-1
LEILFS_VERSION=5.8.0-1 TAG_SUFFIX=ubuntu-24.04 BASE_IMAGE=leil-base:ubuntu-24.04 docker compose up --build

# For Ubuntu 22.04, latest LeilFS version (default)
TAG_SUFFIX=ubuntu-22.04 BASE_IMAGE=leil-base:ubuntu-22.04 docker compose up --build

# For Ubuntu 22.04, pin all components to LeilFS version 5.8.0-1
LEILFS_VERSION=5.8.0-1 TAG_SUFFIX=ubuntu-22.04 BASE_IMAGE=leil-base:ubuntu-22.04 docker compose up --build
```

All images will be tagged as e.g. `leil-master:5.8.0-1-ubuntu-24.04`, `leil-client:latest-ubuntu-22.04`, etc.

To stop and clean up:
```sh
docker compose down
```


To see all built images:
```sh
docker images | grep leil
```

---

## Usage

Clone the repository:

```shell
git clone https://github.com/leil-io/leil-container.git
cd leil-container
```

Builds use the public LeilFS APT repository and do not require credentials.

See the section above for multi-Ubuntu build and tagging instructions.

### Build and Run with Docker
> **Note:**  
> On some systems buildx docker plugin may need to be install prior following step. eg. ubuntu require
> ```shell
> sudo apt install -y docker-buildx
> ```

```shell
# Build the shared base image (no credentials required)
docker build \
  -f leil-base/Dockerfile \
  -t leil-base:ubuntu-24.04 --build-arg BASE_IMAGE=ubuntu:24.04 leil-base/

# Build and start all services
TAG_SUFFIX=ubuntu-24.04 BASE_IMAGE=leil-base:ubuntu-24.04 docker compose up --build
```

### Build and Run with Podman

If you previously created a `./volumes` folder while using Docker, please delete it before deploying with Podman. This prevents permission issues that can occur due to differences in how Docker and Podman handle volume ownership.

```shell
# Build the shared base image (no credentials required)
podman build \
  -f leil-base/Dockerfile \
  -t leil-base:ubuntu-24.04 --build-arg BASE_IMAGE=ubuntu:24.04 leil-base/

# Build and start all services
TAG_SUFFIX=ubuntu-24.04 BASE_IMAGE=leil-base:ubuntu-24.04 podman-compose up --build
```

Visit [http://localhost:29425/sfs.cgi?masterhost=master&masterport=9421](http://localhost:29425/sfs.cgi?masterhost=master&masterport=9421) to access the LeilFS CGI.

## Data Persistence and Initialization

This Docker deployment is designed for ease of use and demonstration.
- **No Pre-committed Data**: The `volumes/` directory is no longer part of this repository.
- **Automatic Initialization**: On first startup, each service (master, metalogger, chunkservers) will automatically:
    - Create necessary configuration files using defaults from the LeilFS packages (found in `/usr/share/doc/saunafs-*/examples/` within the containers).
    - Initialize their respective data directories.
- **Persistent Data**: If you map Docker volumes to the standard LeilFS data and configuration paths (e.g., `/var/lib/saunafs/`, `/etc/saunafs/`), your data and custom configurations will persist across container restarts. If these mapped volumes are empty on first start, they will be initialized as described above.
- **Chunkserver Storage**:
    - Chunkservers will look for mount points at `/mnt/hdd001`, `/mnt/hdd002`, etc.
    - If you provide external volumes mounted to these paths in your `docker-compose.yml`, they will be used.
    - If these paths are not externally mounted, the startup script will create them as directories within the container (volatile storage) and issue a warning. This is suitable for testing but not for production data.

This setup ensures that you can get a LeilFS cluster running quickly without manual configuration steps, while still allowing for persistent storage and custom configurations when needed.

## Cleaning Up Data

If you have used Docker named volumes or host-mounted directories (e.g., by customizing `docker-compose.yml` to map local paths like `./volumes/master/data:/var/lib/saunafs`), your LeilFS data will persist even after containers are stopped and removed.

To completely reset the LeilFS environment and start fresh, you will need to remove this persistent data. 

- **If using Docker named volumes**: You can list them with `docker volume ls` and remove them with `docker volume rm <volume_name>`.
- **If using host-mounted directories**: For example, if you created a local `volumes` directory in your project and mapped subdirectories from it (e.g., `volumes/master/data`, `volumes/chunkserver1/hdd001`, etc.), you would need to manually delete these local directories. 

  **Example for host-mounted `./volumes/` directory:**
  If you had a structure like:
  ```
  your-project-root/
    docker-compose.yml
    volumes/
      master/
        etc/
        var_lib/
      chunkserver1/
        hdd001/
        hdd002/
      ...
  ```
  You would remove the data by deleting the `volumes` directory from your host machine:
  ```shell
  # WARNING: This command permanently deletes data!
  # Ensure you are in your project root and understand the consequences.
  sudo rm -r ./volumes
  ```
  **Be extremely careful with `rm -r` commands.** Double-check the path to ensure you are deleting the correct directory. Incorrect usage can lead to irreversible data loss on your system.

After cleaning up persistent data, the next `docker compose up` will re-initialize everything from scratch using the default configurations.
