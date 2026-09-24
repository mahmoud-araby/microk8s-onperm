-- One database + role per service (mirrors CNPG Database CRs created by the tenant chart).
CREATE ROLE orders   LOGIN PASSWORD 'orders';
CREATE ROLE catalog  LOGIN PASSWORD 'catalog';
CREATE ROLE payments LOGIN PASSWORD 'payments';
CREATE DATABASE orders   OWNER orders;
CREATE DATABASE catalog  OWNER catalog;
CREATE DATABASE payments OWNER payments;
