======================
ZMON Demo Installation
======================

Scripts to install a single node ZMON for demonstration purposes.
Theses scripts are used to bootstrap our public ZMON demo https://demo.zmon.io/.

Usage
=====

You can access the ZMON Controller frontend at https://demo.zmon.io/ with your GitHub credentials.

You can use the `ZMON CLI`_ to add and update check and alert definitions via the REST API,
you need a `personal GitHub access token`_ for this:

.. code-block:: bash

    $ echo "url: https://demo.zmon.io/api/v1\ntoken: <YOUR-GITHUB-TOKEN>" > ~/.zmon-cli.yaml
    $ sudo pip3 install --upgrade zmon-cli
    $ zmon entities  # try REST API, list entities

More information can be found in our `ZMON Documentation`_.


Installation
============

Requirements:

* Clean, empty VM or root server
* Ubuntu 15.10 (might work with other versions too)

.. code-block:: bash

    $ sudo apt-get install git
    $ git clone https://github.com/zalando/zmon-demo.git
    $ cd zmon-demo
    $ sudo ./install.sh

The script will start a Docker "bootstrap" image which will start all required ZMON components as Docker containers.

Known Issues
============

* The boostrap script is not yet completely portable, i.e. it will only work for https://demo.zmon.io/

Let's Encrypt SSL
=================

How to renew SSL certs for the zmon.io and demo.zmon.io domains:

.. code-block:: bash

    $ docker stop zmon-httpd  # make sure the HTTP port is "free"
    $ ./letsencrypt-auto certonly --standalone -d zmon.io -d demo.zmon.io
    $ docker start zmon-httpd


.. _ZMON CLI: https://zmon.readthedocs.org/en/latest/developer/zmon-cli.html
.. _personal GitHub access token: https://help.github.com/articles/creating-an-access-token-for-command-line-use/
.. _ZMON Documentation: https://zmon.readthedocs.org/
