# MCMS for OpenHPC Recipe

[![Join the chat at https://gitter.im/Microway/MCMS-OpenHPC-Recipe](https://badges.gitter.im/Join%20Chat.svg)](https://gitter.im/Microway/MCMS-OpenHPC-Recipe?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge&utm_content=badge)

## This is an experimental work in progress - it is not ready for production

MCMS is Microway's Cluster Management Software. This is not the production-ready
version of MCMS. This is an ongoing project to bring Microway's expertise and
software tools to the recently-announced OpenHPC collaborative framework.

### Purpose
This recipe contains many of the same elements as the official OpenHPC recipe,
but offers a variety of customizations and enhancements, including:

  * Automated power-down of idle compute nodes
  * Support for Mellanox InfiniBand
  * Support for NVIDIA GPU accelerators
  * Monitoring of many additional metrics **(WIP)**
  * More sophisticated log collection and analysis **(WIP)**
  * Nagios-compatible monitoring with a more modern interface **(WIP)**

### Installation
*Given a vanilla CentOS 7.x installation, this collection of scripts will stand
up an OpenHPC cluster. This script will be tested with fresh installations -
attempting to run it on an installation that's had a lot of changes may break.*

```
# Use your favorite text editor to customize the install
vim configuration_settings.txt

# Run the installation on the new Head Node
./install_head_node.sh
```

### More Information
If you would like to purchase professional support/services for an OpenHPC
cluster, or to fund development of a new feature, please visit:
https://www.microway.com/contact/

To learn more about OpenHPC or to view the official installation recipe, visit:
http://www.openhpc.community/

