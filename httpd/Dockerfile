FROM httpd:2.4

COPY httpd-foreground /usr/local/bin/

COPY httpd.conf /usr/local/apache2/conf/httpd.conf
COPY httpd-ssl.conf /usr/local/apache2/conf/httpd-ssl.conf
COPY httpd-vhosts.conf /usr/local/apache2/conf/httpd-vhosts.conf

COPY htdocs/ /usr/local/apache2/htdocs/

ENTRYPOINT ["/usr/local/bin/httpd-foreground"]
