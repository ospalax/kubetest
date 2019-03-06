#!/bin/sh

set -e

#
# Do simple checks on kubetest1 deployment
#

KUBETEST_MANIFEST=kubetest1-manifest.yaml
MYSQL_ROOT_PASSWORD=kubetest
MYSQL_KUBETEST_CHECK_VALUE='MYSQL KUBETEST SUCCESS'


# functions

on_exit()
{
    echo REPORT
}


# start

trap on_exit EXIT


# gather info about kubernetes cluster

echo 'KUBETEST INFO: Get nodes ip addresses'
kube_nodes=$(kubectl get nodes -o json | jq -cr '.items[] | .status.addresses[] | select(.type == "InternalIP") | .address')
kube_nodes_count=$(echo "$kube_nodes" | wc -w)

if [ "$kube_nodes_count" -eq 0 ] ; then
    echo 'KUBETEST ERROR: No nodes in cluster'
    exit 1
elif [ "$kube_nodes_count" -eq 1 ] ; then
    MULTI_NODE=no
    ANTI_AFFINITY=''
else
    MULTI_NODE=yes
    ANTI_AFFINITY=Anti
fi

echo 'KUBETEST INFO: Find master node ip'
kube_master_node=$(kubectl get nodes -o wide | awk '{if ($3 == "master") print $6;}' | sort -u | head -n 1)

ip_match=no
for ip in $kube_nodes ; do
    if [ "$ip" = "$kube_master_node" ] ; then
        ip_match=yes
        break
    fi
done

if [ "$ip_match" != yes ] ; then
    echo 'KUBETEST ERROR: Cannot detect master node ip'
    exit 1
fi


# deploy pods and services

echo 'KUBETEST INFO: (Re)deploy kubetest'
cat "$KUBETEST_MANIFEST" > "$KUBETEST_MANIFEST".expanded
sed -i -e 's/[$]{ANTI_AFFINITY}/'"$ANTI_AFFINITY"'/g' \
    -e 's/[$]{PUBLIC_IP}/'"$kube_master_node"'/g' \
    -e 's/[$]{MYSQL_ROOT_PASSWORD}/'"$MYSQL_ROOT_PASSWORD"'/g' \
    "$KUBETEST_MANIFEST".expanded
kubectl apply -f "$KUBETEST_MANIFEST".expanded

echo 'KUBETEST INFO: Wait for kubetest pod...'
while [ "$(kubectl get pods --selector=app=kubetest_pod -o json \
        | jq '.items[0].status.containerStatuses[0].ready')" != true ] ;
do
    sleep 2s
done

echo 'KUBETEST INFO: Wait for mysql pod...'
while [ "$(kubectl get pods --selector=app=mysql_pod -o json \
        | jq '.items[0].status.containerStatuses[0].ready')" != true ] ;
do
    sleep 2s
done


# gather info about pods

echo 'KUBETEST INFO: Get kubetest pod ip address and name'
kubetest_pod_hostip=$(kubectl get pods --selector=app=kubetest_pod -o jsonpath='{.items[*].status.hostIP}')
kubetest_pod_name=$(kubectl get pods --selector=app=kubetest_pod -o jsonpath='{.items[*].metadata.name}')

echo 'KUBETEST INFO: Get mysql pod ip address and name'
mysql_pod_hostip=$(kubectl get pods --selector=app=mysql_pod -o jsonpath='{.items[*].status.hostIP}')
mysql_pod_name=$(kubectl get pods --selector=app=mysql_pod -o jsonpath='{.items[*].metadata.name}')

if [ -z "$kubetest_pod_hostip" ] || [ -z "$mysql_pod_hostip" ] ; then
    echo 'KUBETEST ERROR: Could not get hostIP of a pod'
    exit 1
fi

if [ "$MULTI_NODE" = yes ] && [ "$kubetest_pod_hostip" = "$mysql_pod_hostip" ] ; then
    echo 'KUBETEST ERROR: Pods are colocated on one node'
    exit 1
fi


# populate mysql

echo 'KUBETEST INFO: Populate mysql'
kubectl exec "$mysql_pod_name" -it -- mysql -u root -p${MYSQL_ROOT_PASSWORD} <<EOF
CREATE DATABASE IF NOT EXISTS kubetest;

USE kubetest;

DROP TABLE IF EXISTS kubetest;

CREATE TABLE kubetest (
  kubetest_check_value varchar(60) DEFAULT NULL
);

INSERT INTO kubetest(kubetest_check_value) VALUES ('${MYSQL_KUBETEST_CHECK_VALUE}');
EOF


# Check published kubetest service

echo 'KUBETEST INFO: Check kubetest http port 80 on master node'
curl "${kube_master_node}:80"

exit 0

#mysql> create database kubetest;
#mysql> use kubetest;
#mysql> create table kubetest(kubetest_check_value varchar(60));
#mysql> insert into kubetest (kubetest_check_value) values ('MYSQL KUBETEST SUCCESS');
#mysql> select kubetest_check_value from kubetest.kubetest;
