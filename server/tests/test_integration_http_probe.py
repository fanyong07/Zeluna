"""The production verifier must reject empty routes and partially failed checks."""
from copy import deepcopy

import pytest

from tools.verify_integrations_http import acceptance_checks


def good_checks():
    lines = {'lines': 2, 'cached': 2, 'wrappers': 0, 'private_urls': 0,
             'media_proxy_urls': 0, 'internal_label_leaks': 0, 'private_cache_keys': 0}
    return {'providers_enabled': {'ok': True}, 'anich_episodes': {'count': 12},
            'animeko_episodes': {'count': 28}, 'kazumi_episodes': {'count': 84},
            'anich_vod': dict(lines), 'anich_cached_vod': dict(lines),
            'animeko_vod': dict(lines), 'stable_v3': dict(lines),
            'kazumi_no_playback': {'ok': True}, 'anich_media_sample': {'ok': True},
            'animeko_media_sample': {'ok': True}}


def test_acceptance_requires_every_explicit_evidence_field():
    checks = good_checks()
    assert acceptance_checks(checks) == []
    assert acceptance_checks(checks, stable_requested=True) == []
    for key in checks:
        broken = deepcopy(checks)
        del broken[key]
        if key == 'stable_v3':
            assert acceptance_checks(broken, stable_requested=True)
        else:
            assert acceptance_checks(broken)


@pytest.mark.parametrize('field', ['wrappers', 'private_urls', 'media_proxy_urls', 'internal_label_leaks', 'private_cache_keys'])
def test_any_route_leak_fails_gate(field):
    for name in ('anich_vod', 'anich_cached_vod', 'animeko_vod'):
        broken = good_checks()
        broken[name][field] = 1
        assert any(field in failure for failure in acceptance_checks(broken))


def test_empty_anich_and_unexpected_kazumi_media_regression():
    broken = good_checks()
    broken['anich_vod']['lines'] = 0
    broken['anich_cached_vod']['lines'] = 0
    broken['anich_cached_vod']['cached'] = 0
    broken['kazumi_no_playback']['ok'] = False
    failures = acceptance_checks(broken, no_animeko_vod=True)
    assert 'anich_vod-empty' in failures
    assert 'anich-cache-not-hit' in failures
    assert 'kazumi-returned-media' in failures


def test_skip_animeko_media_only_skips_its_vod_and_sample():
    checks = good_checks()
    del checks['animeko_vod']
    del checks['animeko_media_sample']
    assert acceptance_checks(checks, no_animeko_vod=True) == []
    checks['animeko_episodes']['count'] = 0
    assert acceptance_checks(checks, no_animeko_vod=True)
