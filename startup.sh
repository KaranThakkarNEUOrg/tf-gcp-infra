#!/bin/bash
if [ ! -f /opt/webapp/.env ]; then
    sudo echo "MYSQL_HOSTNAME=${sql_hostname}" | sudo tee -a /opt/webapp/.env
    sudo echo "MYSQL_PASSWORD=${sql_password}" | sudo tee -a /opt/webapp/.env
    sudo echo "MYSQL_DATABASENAME=${sql_databasename}" | sudo tee -a /opt/webapp/.env
    sudo echo "MYSQL_USERNAME=${sql_username}" | sudo tee -a /opt/webapp/.env
    sudo echo "PORT=${sql_port}" | sudo tee -a /opt/webapp/.env
    sudo echo "SALT_ROUNDS=${salt_rounds}" | sudo tee -a /opt/webapp/.env
fi
sudo touch /opt/finish.txt
sudo chown -R csye6225:csye6225 /opt/webapp/
sudo chmod 700 /opt/webapp/
