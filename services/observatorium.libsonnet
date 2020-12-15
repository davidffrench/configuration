local api = (import 'github.com/observatorium/observatorium/jsonnet/lib/observatorium-api.libsonnet');
local up = (import 'github.com/observatorium/up/jsonnet/up.libsonnet');
local gubernator = (import 'github.com/observatorium/deployments/components/gubernator.libsonnet');

(import 'github.com/observatorium/deployments/components/observatorium.libsonnet') +
(import 'observatorium-metrics.libsonnet') +
(import 'observatorium-metrics-template-overwrites.libsonnet') +
(import 'observatorium-logs.libsonnet') +
(import 'observatorium-logs-template-overwrites.libsonnet') +
{
  local obs = self,

  config:: {
    name: 'observatorium',
    namespace: '${NAMESPACE}',

    commonLabels:: {
      'app.kubernetes.io/part-of': 'observatorium',
      'app.kubernetes.io/instance': obs.config.name,
    },
  },

  gubernator:: gubernator({
    local cfg = self,
    name: obs.config.name + '-' + cfg.commonLabels['app.kubernetes.io/name'],
    namespace: obs.config.namespace,
    version: '${GUBERNATOR_IMAGE_TAG}',
    image: '%s:%s' % ['${GUBERNATOR_IMAGE}', cfg.version],
    replicas: 1,
    commonLabels+:: obs.config.commonLabels,
    serviceMonitor: true,
    resources: {
      requests: {
        cpu: '${GUBERNATOR_CPU_REQUEST}',
        memory: '${GUBERNATOR_MEMORY_REQUEST}',
      },
      limits: {
        cpu: '${GUBERNATOR_CPU_LIMIT}',
        memory: '${GUBERNATOR_MEMORY_LIMIT}',
      },
    },
  }) {
    deployment+: {
      spec+: {
        replicas: '${{GUBERNATOR_REPLICAS}}',
      },
    },
    serviceMonitor+: {
      metadata+: {
        name: 'observatorium-gubernator',
        labels+: {
          prometheus: 'app-sre',
          'app.kubernetes.io/version':: 'hidden',
        },
      },
      spec+: {
        selector+: {
          matchLabels+: {
            'app.kubernetes.io/version':: 'hidden',
          },
        },
        namespaceSelector+: { matchNames: ['${NAMESPACE}'] },
      },
    },
  },

  api:: api({
    local cfg = self,
    name: 'observatorium-observatorium-api',
    commonLabels:: {
      'app.kubernetes.io/component': 'api',
      'app.kubernetes.io/instance': 'observatorium',
      'app.kubernetes.io/name': 'observatorium-api',
      'app.kubernetes.io/part-of': 'observatorium',
      'app.kubernetes.io/version': '${OBSERVATORIUM_API_IMAGE_TAG}',
    },
    version: '${OBSERVATORIUM_API_IMAGE_TAG}',
    image: '%s:%s' % ['${OBSERVATORIUM_API_IMAGE}', cfg.version],
    replicas: 1,
    serviceMonitor: true,
    logs: {
      readEndpoint: 'http://%s.%s.svc.cluster.local:%d' % [
        obs.loki.manifests['query-frontend-http-service'].metadata.name,
        '${OBSERVATORIUM_LOGS_NAMESPACE}',
        obs.loki.manifests['query-frontend-http-service'].spec.ports[0].port,
      ],
      tailEndpoint: 'http://%s.%s.svc.cluster.local:%d' % [
        obs.loki.manifests['querier-http-service'].metadata.name,
        '${OBSERVATORIUM_LOGS_NAMESPACE}',
        obs.loki.manifests['querier-http-service'].spec.ports[0].port,
      ],
      writeEndpoint: 'http://%s.%s.svc.cluster.local:%d' % [
        obs.loki.manifests['distributor-http-service'].metadata.name,
        '${OBSERVATORIUM_LOGS_NAMESPACE}',
        obs.loki.manifests['distributor-http-service'].spec.ports[0].port,
      ],
    },
    metrics: {
      readEndpoint: 'http://%s.%s.svc.cluster.local:%d' % [
        obs.thanos.queryFrontend.service.metadata.name,
        obs.thanos.queryFrontend.service.metadata.namespace,
        obs.thanos.queryFrontend.service.spec.ports[0].port,
      ],
      writeEndpoint: 'http://%s.%s.svc.cluster.local:%d' % [
        obs.thanos.receiversService.metadata.name,
        obs.thanos.receiversService.metadata.namespace,
        obs.thanos.receiversService.spec.ports[2].port,
      ],
    },
    rateLimiter: {
      grpcAddress: '%s.%s.svc.cluster.local:%d' % [
        obs.gubernator.service.metadata.name,
        obs.gubernator.service.metadata.namespace,
        obs.gubernator.config.ports.grpc,
      ],
    },
    rbac: (import '../configuration/observatorium/rbac.libsonnet'),
    tenants: (import '../configuration/observatorium/tenants.libsonnet'),
    resources: {
      requests: {
        cpu: '${OBSERVATORIUM_API_CPU_REQUEST}',
        memory: '${OBSERVATORIUM_API_MEMORY_REQUEST}',
      },
      limits: {
        cpu: '${OBSERVATORIUM_API_CPU_LIMIT}',
        memory: '${OBSERVATORIUM_API_MEMORY_LIMIT}',
      },
    },
  }) + {
    // TODO: Enable in a separate MR.
    // local oauth = (import 'sidecars/oauth-proxy.libsonnet')({
    //   name: 'observatorium-api',
    //   image: '${OAUTH_PROXY_IMAGE}:${OAUTH_PROXY_IMAGE_TAG}',
    //   httpsPort: 9091,
    //   upstream: 'http://localhost:' + obs.api.service.spec.ports[1].port,
    //   tlsSecretName: 'observatorium-api-tls',
    //   sessionSecretName: 'observatorium-api-proxy',
    //   serviceAccountName: 'observatorium-api',
    //   resources: {
    //     requests: {
    //       cpu: '${OAUTH_PROXY_CPU_REQUEST}',
    //       memory: '${OAUTH_PROXY_MEMORY_REQUEST}',
    //     },
    //     limits: {
    //       cpu: '${OAUTH_PROXY_CPU_LIMITS}',
    //       memory: '${OAUTH_PROXY_MEMORY_LIMITS}',
    //     },
    //   },
    // }),

    local opaAms = (import 'sidecars/opa-ams.libsonnet')({
      image: '${OPA_AMS_IMAGE}:${OPA_AMS_IMAGE_TAG}',
      clientIDKey: 'client-id',
      clientSecretKey: 'client-secret',
      secretName: obs.api.config.name,
      issuerURLKey: 'issuer-url',
      amsURL: '${AMS_URL}',
      memcached: 'memcached-0.memcached.${NAMESPACE}.svc.cluster.local:11211',
      memcachedExpire: '${OPA_AMS_MEMCACHED_EXPIRE}',
      opaPackage: 'observatorium',
      resourceTypePrefix: 'observatorium',
      resources: {
        requests: {
          cpu: '${OPA_AMS_CPU_REQUEST}',
          memory: '${OPA_AMS_MEMORY_REQUEST}',
        },
        limits: {
          cpu: '${OPA_AMS_CPU_LIMIT}',
          memory: '${OPA_AMS_MEMORY_LIMIT}',
        },
      },
    }),

    // proxySecret: oauth.proxySecret,

    // service+: oauth.service + opaAms.service,
    service+: opaAms.service,

    deployment+: {
      spec+: {
        replicas: '${{OBSERVATORIUM_API_REPLICAS}}',
      },
    } + opaAms.deployment,
    // + oauth.deployment

    configmap+: {
      metadata+: {
        annotations+: { 'qontract.recycle': 'true' },
      },
    },

    serviceMonitor+: {
      metadata+: {
        name: 'observatorium-api',
        labels+: {
          prometheus: 'app-sre',
          'app.kubernetes.io/version':: 'hidden',
        },
      },
      spec+: {
        selector+: {
          matchLabels+: {
            'app.kubernetes.io/version':: 'hidden',
          },
        },
        namespaceSelector+: { matchNames: ['${NAMESPACE}'] },
      },
    } + opaAms.serviceMonitor,
  },

  up:: up({
    local cfg = self,
    name: obs.config.name + '-' + cfg.commonLabels['app.kubernetes.io/name'],
    namespace: obs.config.namespace,
    commonLabels+:: obs.config.commonLabels,
    version: 'master-2020-06-15-d763595',
    image: 'quay.io/observatorium/up:' + cfg.version,
    replicas: 1,
    endpointType: 'metrics',
    readEndpoint: 'http://%s.%s.svc:9090/api/v1/query' % [obs.thanos.queryFrontend.service.metadata.name, obs.thanos.queryFrontend.service.metadata.namespace],
    queryConfig: (import '../configuration/observatorium/queries.libsonnet'),
    serviceMonitor: true,
    resources: {
      requests: {
        cpu: '5m',
        memory: '10Mi',
      },
      limits: {
        cpu: '20m',
        memory: '50Mi',
      },
    },
  }) {
    serviceMonitor+: {
      metadata+: {
        name: 'observatorium-up',
        labels+: {
          prometheus: 'app-sre',
          'app.kubernetes.io/version':: 'hidden',
        },
      },
      spec+: { namespaceSelector+: { matchNames: ['${NAMESPACE}'] } },
    },
  },

  manifests+:: {
    ['observatorium-up-' + name]: obs.up[name]
    for name in std.objectFields(obs.up)
    if obs.up[name] != null
  },
}