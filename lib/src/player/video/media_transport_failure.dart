enum MediaTransportFailureKind {
  http,
  timeout,
  tls,
  connection,
  policy,
  manifest,
  unknown,
}

final class MediaTransportFailure {
  const MediaTransportFailure(this.kind, {required this.manifest, this.status});
  final MediaTransportFailureKind kind;
  final bool manifest;
  final int? status;
  Map<String, Object?> get safeFields => {
    'reason_code': kind.name,
    'resource_type': manifest ? 'manifest' : 'media',
    if (status != null) 'http_status': status,
  };
}
