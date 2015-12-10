# MCMS for OpenHPC Recipe

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
  * Monitoring of many additional metrics *(WIP)*
  * More sophisticated log collection and analysis *(WIP)*
  * Nagios-compatible monitoring with a more modern interface *(WIP)*

Given a vanilla CentOS 7.x installation, this collection of scripts will stand
up an OpenHPC cluster.

### More Information
To learn more about OpenHPC and view the official installation recipe, visit:
http://www.openhpc.community/

