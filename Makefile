.PHONY: setup-minikube-same-network delete-minikube-same-network \
        setup-microshift-same-network delete-microshift-same-network

setup-minikube-same-network:
	bash ./hack/setup-minikube-same-network.sh

delete-minikube-same-network:
	minikube delete -p src || true
	minikube delete -p tgt || true

setup-microshift-same-network:
	bash ./hack/setup-microshift-same-network.sh

delete-microshift-same-network:
	docker rm -f microshift-src microshift-tgt || true
	docker volume rm microshift-src-data microshift-tgt-data || true
	docker network rm microshift-mc || true