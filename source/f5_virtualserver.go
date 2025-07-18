/*
Copyright 2022 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package source

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"strings"

	log "github.com/sirupsen/logrus"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/dynamic/dynamicinformer"
	kubeinformers "k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/tools/cache"

	f5 "github.com/F5Networks/k8s-bigip-ctlr/v2/config/apis/cis/v1"

	"sigs.k8s.io/external-dns/endpoint"
	"sigs.k8s.io/external-dns/source/annotations"
	"sigs.k8s.io/external-dns/source/informers"
)

var f5VirtualServerGVR = schema.GroupVersionResource{
	Group:    "cis.f5.com",
	Version:  "v1",
	Resource: "virtualservers",
}

// virtualServerSource is an implementation of Source for F5 VirtualServer objects.
type f5VirtualServerSource struct {
	dynamicKubeClient     dynamic.Interface
	virtualServerInformer kubeinformers.GenericInformer
	kubeClient            kubernetes.Interface
	annotationFilter      string
	namespace             string
	unstructuredConverter *unstructuredConverter
}

func NewF5VirtualServerSource(
	ctx context.Context,
	dynamicKubeClient dynamic.Interface,
	kubeClient kubernetes.Interface,
	namespace string,
	annotationFilter string,
) (Source, error) {
	informerFactory := dynamicinformer.NewFilteredDynamicSharedInformerFactory(dynamicKubeClient, 0, namespace, nil)
	virtualServerInformer := informerFactory.ForResource(f5VirtualServerGVR)

	virtualServerInformer.Informer().AddEventHandler(
		cache.ResourceEventHandlerFuncs{
			AddFunc: func(obj interface{}) {
			},
		},
	)

	informerFactory.Start(ctx.Done())

	// wait for the local cache to be populated.
	if err := informers.WaitForDynamicCacheSync(context.Background(), informerFactory); err != nil {
		return nil, err
	}

	uc, err := newVSUnstructuredConverter()
	if err != nil {
		return nil, fmt.Errorf("failed to setup unstructured converter: %w", err)
	}

	return &f5VirtualServerSource{
		dynamicKubeClient:     dynamicKubeClient,
		virtualServerInformer: virtualServerInformer,
		kubeClient:            kubeClient,
		namespace:             namespace,
		annotationFilter:      annotationFilter,
		unstructuredConverter: uc,
	}, nil
}

// Endpoints returns endpoint objects for each host-target combination that should be processed.
// Retrieves all VirtualServers in the source's namespace(s).
func (vs *f5VirtualServerSource) Endpoints(ctx context.Context) ([]*endpoint.Endpoint, error) {
	virtualServerObjects, err := vs.virtualServerInformer.Lister().ByNamespace(vs.namespace).List(labels.Everything())
	if err != nil {
		return nil, err
	}

	var virtualServers []*f5.VirtualServer
	for _, vsObj := range virtualServerObjects {
		unstructuredHost, ok := vsObj.(*unstructured.Unstructured)
		if !ok {
			return nil, errors.New("could not convert")
		}

		virtualServer := &f5.VirtualServer{}
		err := vs.unstructuredConverter.scheme.Convert(unstructuredHost, virtualServer, nil)
		if err != nil {
			return nil, err
		}
		virtualServers = append(virtualServers, virtualServer)
	}

	virtualServers, err = vs.filterByAnnotations(virtualServers)
	if err != nil {
		return nil, fmt.Errorf("failed to filter VirtualServers: %w", err)
	}

	endpoints, err := vs.endpointsFromVirtualServers(virtualServers)
	if err != nil {
		return nil, err
	}

	// Sort endpoints
	for _, ep := range endpoints {
		sort.Sort(ep.Targets)
	}

	return endpoints, nil
}

func (vs *f5VirtualServerSource) AddEventHandler(ctx context.Context, handler func()) {
	log.Debug("Adding event handler for VirtualServer")

	vs.virtualServerInformer.Informer().AddEventHandler(eventHandlerFunc(handler))
}

// endpointsFromVirtualServers extracts the endpoints from a slice of VirtualServers
func (vs *f5VirtualServerSource) endpointsFromVirtualServers(virtualServers []*f5.VirtualServer) ([]*endpoint.Endpoint, error) {
	var endpoints []*endpoint.Endpoint

	for _, virtualServer := range virtualServers {
		if !hasValidVirtualServerIP(virtualServer) {
			log.Warnf("F5 VirtualServer %s/%s is missing a valid IP address, skipping endpoint creation.",
				virtualServer.Namespace, virtualServer.Name)
			continue
		}

		resource := fmt.Sprintf("f5-virtualserver/%s/%s", virtualServer.Namespace, virtualServer.Name)

		ttl := annotations.TTLFromAnnotations(virtualServer.Annotations, resource)

		targets := annotations.TargetsFromTargetAnnotation(virtualServer.Annotations)
		if len(targets) == 0 && virtualServer.Spec.VirtualServerAddress != "" {
			targets = append(targets, virtualServer.Spec.VirtualServerAddress)
		}

		if len(targets) == 0 && virtualServer.Status.VSAddress != "" {
			targets = append(targets, virtualServer.Status.VSAddress)
		}

		endpoints = append(endpoints, EndpointsForHostname(virtualServer.Spec.Host, targets, ttl, nil, "", resource)...)
	}

	return endpoints, nil
}

// newUnstructuredConverter returns a new unstructuredConverter initialized
func newVSUnstructuredConverter() (*unstructuredConverter, error) {
	uc := &unstructuredConverter{
		scheme: runtime.NewScheme(),
	}

	// Add the core types we need
	uc.scheme.AddKnownTypes(f5VirtualServerGVR.GroupVersion(), &f5.VirtualServer{}, &f5.VirtualServerList{})
	if err := scheme.AddToScheme(uc.scheme); err != nil {
		return nil, err
	}

	return uc, nil
}

// filterByAnnotations filters a list of VirtualServers by a given annotation selector.
func (vs *f5VirtualServerSource) filterByAnnotations(virtualServers []*f5.VirtualServer) ([]*f5.VirtualServer, error) {
	selector, err := annotations.ParseFilter(vs.annotationFilter)
	if err != nil {
		return nil, err
	}

	// empty filter returns original list
	if selector.Empty() {
		return virtualServers, nil
	}

	filteredList := []*f5.VirtualServer{}

	for _, vs := range virtualServers {
		// include VirtualServer if its annotations match the selector
		if selector.Matches(labels.Set(vs.Annotations)) {
			filteredList = append(filteredList, vs)
		}
	}

	return filteredList, nil
}

func hasValidVirtualServerIP(vs *f5.VirtualServer) bool {
	normalizedAddress := strings.ToLower(vs.Status.VSAddress)
	return normalizedAddress != "none" && normalizedAddress != ""
}
