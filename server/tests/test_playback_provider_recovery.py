"""Healthy routes must not freeze failed providers for the positive-cache TTL."""
import json
import time
from types import SimpleNamespace
import pytest
from server.playback import PlaybackService

def row(age, status):
    lines = [dict(url=f'https://cdn.example/episode-{i}.mp4', source=f'maccms:ok-{i}',
                  status='server_verified', available=True, headers={}) for i in range(5)]
    lines.append(dict(url='', source='crawler:anich', status='unavailable',
                      diagnostic_status=status, queried=True, available=False))
    return SimpleNamespace(lines_json=json.dumps(lines),line_count=5,verified_at=time.time()-age,scan_scope='full')

@pytest.mark.parametrize('failure',['search_error','search_timeout','route_unavailable','circuit_suppressed'])
def test_transient_failed_provider_retries_without_discarding_good_routes(failure):
    state, lines = PlaybackService._cache_state_and_items(row(120, failure))
    assert state == 'stale'
    assert sum(bool(x.get('url')) for x in lines) == 5

@pytest.mark.parametrize('status',['search_miss','unsupported_content_type','server_verified'])
def test_confirmed_observations_keep_normal_positive_cache(status):
    assert PlaybackService._cache_state_and_items(row(120,status))[0] == 'fresh'

def test_recent_transient_failure_does_not_create_a_retry_storm():
    assert PlaybackService._cache_state_and_items(row(10,'search_error'))[0] == 'fresh'
