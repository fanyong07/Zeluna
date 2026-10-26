/// The probe and the decoder must present the same default media identity.
/// Explicit source headers always win, including differently cased names.
const defaultMediaUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

Map<String, String> effectiveMediaRequestHeaders(Map<String, String> headers) =>
    {
      if (!headers.keys.any((name) => name.toLowerCase() == 'user-agent'))
        'User-Agent': defaultMediaUserAgent,
      ...headers,
    };
