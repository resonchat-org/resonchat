// Copyright (C) 2026 ResonChat contributors.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// Built-in rules translated from Untracker BuiltinRuleList.kt (enabled rules
// only). No user-editable rule set — fixed list like Copinc.

import 'rule.dart';
import 'url.dart';

/// Untracker built-in rules (enabled entries from BuiltinRuleList).
List<UntrackRule> builtinUntrackRules() => [
  const _CommonRedirections(),
  const _CommonShortLinks(),
  const _CommonAnalytics(),
  const _CommonAds(),
  const _Amazon(),
  const _Bilibili(),
  const _Douban(),
  const _Douyin(),
  const _GoogleSearch(),
  const _Instagram(),
  const _Jd(),
  const _Kuaishou(),
  const _NetEaseCloudMusic(),
  const _Netflix(),
  const _Pinterest(),
  const _Reddit(),
  const _Rednote(),
  const _Smzdm(),
  const _Spotify(),
  const _StackExchange(),
  const _Taobao(),
  const _Threads(),
  const _TikTok(),
  const _X(),
  const _Youtube(),
];

class _CommonRedirections extends LocalUntrackRule {
  const _CommonRedirections()
    : super(
        id: '0db0b0dc-f46f-40a4-8c0d-8a575a09f2a3',
        description: 'Remove common redirections',
      );

  @override
  String clean(TrackUrl url) {
    if (url.matches('www\\.douban\\.com', '/link2/', r'.*\burl=.+')) {
      return url.queryParameter('url') ?? url.toString();
    }
    if (url.matches('search\\.app', '/', r'.*\blink=.+')) {
      return url.queryParameter('link') ?? url.toString();
    }
    if (url.matches('link\\.zhihu\\.com', '/', r'.*\btarget=.+')) {
      return url.queryParameter('target') ?? url.toString();
    }
    return url.toString();
  }
}

class _CommonShortLinks extends UntrackRule {
  const _CommonShortLinks()
    : super(
        id: 'a925a9f0-84bb-46eb-bea2-1bded576d8c9',
        description: 'Expand common tracking short links',
      );

  static bool _isShort(TrackUrl url) =>
      url.matches(
        r'163cn\.tv|a\.co|amzn\.(asia|eu|to)|b23\.tv|bili2233\.cn|v\.douyin\.com|dwz\.cn|u\.jd\.com|v\.kuaishou\.com|pin\.it|share\.google|t\.cn|vm\.tiktok\.com|url\.cn|xhslink\.(cn|com)',
      ) ||
      url.matches(r'm\.gifshow\.com', r'/s/.+') ||
      url.matches(r'www\.google\.com', r'/share\.google') ||
      url.matches(r'www\.instagram\.com', r'/share/reel/.+') ||
      url.matches(r'api\.pinterest\.com', r'/url_shortener/.+') ||
      url.matches(r'www\.reddit\.com', r'/r/[^/]+/s/.+') ||
      url.matches(r'search\.app', r'/.+') ||
      url.matches(r'([cm]\.)?tb\.cn');

  static bool _isRedirectShort(TrackUrl url) =>
      url.matches(
        r'163cn\.tv|a\.co|amzn\.(asia|eu|to)|b23\.tv|bili2233\.cn|v\.douyin\.com|dwz\.cn|u\.jd\.com|v\.kuaishou\.com|pin\.it|share\.google|t\.cn|vm\.tiktok\.com|url\.cn|xhslink\.(cn|com)',
      ) ||
      url.matches(r'm\.gifshow\.com', r'/s/.+') ||
      url.matches(r'www\.google\.com', r'/share\.google') ||
      url.matches(r'www\.instagram\.com', r'/share/reel/.+') ||
      url.matches(r'api\.pinterest\.com', r'/url_shortener/.+') ||
      url.matches(r'www\.reddit\.com', r'/r/[^/]+/s/.+') ||
      url.matches(r'search\.app', r'/.+');

  @override
  bool inspect(TrackUrl url) => _isShort(url);

  @override
  Future<String> untrack(TrackUrl url, UntrackFetch fetch) async {
    var current = url;
    while (true) {
      if (_isRedirectShort(current)) {
        final response = await fetch(
          current.toString(),
          followRedirects: false,
        );
        if ({301, 302, 303, 307, 308}.contains(response.status)) {
          String? location;
          response.headers.forEach((k, v) {
            if (k.toLowerCase() == 'location') location = v;
          });
          if (location != null && location!.isNotEmpty) {
            final resolved = Uri.parse(current.toString()).resolve(location!);
            current = TrackUrl(normalizeUrlString(resolved.toString()));
            continue;
          }
        }
      } else if (current.matches(r'([cm]\.)?tb\.cn')) {
        final response = await fetch(current.toString(), followRedirects: true);
        final m = RegExp(r"var url = '([^']+)'").firstMatch(response.body);
        if (m != null) {
          current = TrackUrl(normalizeUrlString(m.group(1)!));
          continue;
        }
      }
      break;
    }
    return current.toString();
  }
}

class _CommonAnalytics extends LocalUntrackRule {
  const _CommonAnalytics()
    : super(
        id: '19d74b86-5ac0-4218-8ec8-ee89e4d237f1',
        description: 'Remove tracking for common analytics',
      );

  @override
  String clean(TrackUrl url) =>
      url.removeQueryParameters(r'[isu]tm_.*|ref').toString();
}

class _CommonAds extends LocalUntrackRule {
  const _CommonAds()
    : super(
        id: '87af5849-1e81-42bd-984e-e30a1ec08db4',
        description: 'Remove tracking for common ads',
      );

  @override
  String clean(TrackUrl url) => url
      .removeQueryParameters(r'(fb|g|tt|wicked|y)cl(id|source|src)|[gw]braid')
      .toString();
}

class _Amazon extends LocalUntrackRule {
  const _Amazon()
    : super(
        id: '3805dd66-b341-4da3-b5ba-f3acc69ed189',
        description: 'Remove tracking for Amazon',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(
      r'.+\.amazon\.(ae|ca|cn|co\.jp|co\.uk|com|com\.au|com\.be|com\.br|com\.mx|com\.tr|de|eg|es|fr|in|it|nl|pl|sa|se|sg)',
    )) {
      return url.toString();
    }
    var u = url.setEncodedQuery(null);
    final path = u.encodedPath;
    final cleaned = path.replaceFirst(
      RegExp(r'/ref=.+$', caseSensitive: false),
      '',
    );
    if (cleaned != path) u = u.setEncodedPath(cleaned);
    return u.toString();
  }
}

class _Bilibili extends LocalUntrackRule {
  const _Bilibili()
    : super(
        id: '7edf803f-c165-46ef-b4d1-b8cbc6b5cb65',
        description: 'Remove tracking for Bilibili',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(r'.+\.bilibili\.com')) return url.toString();
    return url
        .retainQueryParameters(
          r'business_id|business_type|itemsId|lottery_id|p|start_progress|t',
        )
        .removeQueryParameters('p', '1')
        .toString();
  }
}

class _Douban extends LocalUntrackRule {
  const _Douban()
    : super(
        id: 'ad21dada-9f09-4adf-9db2-d1575ca8b4a4',
        description: 'Remove tracking for Douban',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(r'.+\.douban\.com')) return url.toString();
    return url.setEncodedQuery(null).toString();
  }
}

class _Douyin extends LocalUntrackRule {
  const _Douyin()
    : super(
        id: 'c112da1e-384e-42e2-b110-ce6d8edbfe7a',
        description: 'Remove tracking for Douyin',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(r'.+\.(douyin|iesdouyin)\.com')) return url.toString();
    return url.setEncodedQuery(null).toString();
  }
}

class _GoogleSearch extends LocalUntrackRule {
  const _GoogleSearch()
    : super(
        id: '926090a8-a98a-4168-b6a1-b6b801c76955',
        description: 'Remove tracking for Google Search',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(r'www\.google\.com', '/search')) return url.toString();
    return url.retainQueryParameters(r'q|tbm').toString();
  }
}

class _Instagram extends LocalUntrackRule {
  const _Instagram()
    : super(
        id: 'bcd9fcb8-bf1c-41f8-b18d-b248507e43c7',
        description: 'Remove tracking for Instagram',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(r'www\.instagram\.com')) return url.toString();
    return url.setEncodedQuery(null).toString();
  }
}

class _Jd extends LocalUntrackRule {
  const _Jd()
    : super(
        id: 'c68c4cbf-9ae5-41f6-89ba-6e3f31ffb6a2',
        description: 'Remove tracking for JD.com',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(r'.+\.jd\.com')) return url.toString();
    return url
        .retainQueryParameters(r'id|shopId|skuIds|suitId|wareId')
        .toString();
  }
}

class _Kuaishou extends LocalUntrackRule {
  const _Kuaishou()
    : super(
        id: '1d0c3aae-c456-4352-972a-8b0b0f6e36c1',
        description: 'Remove tracking for Kuaishou',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(
      r'(.+\.)?m\.chenzhongtech\.com|m\.gifshow\.com|.+\.kuaishou\.com',
    )) {
      return url.toString();
    }
    return url.setEncodedQuery(null).toString();
  }
}

class _NetEaseCloudMusic extends LocalUntrackRule {
  const _NetEaseCloudMusic()
    : super(
        id: 'c722500a-17c8-462a-8a74-0c15fefe1b3e',
        description: 'Remove tracking for NetEase Cloud Music',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(r'y\.music\.163\.com')) return url.toString();
    return url.retainQueryParameters('id').toString();
  }
}

class _Netflix extends LocalUntrackRule {
  const _Netflix()
    : super(
        id: '465d579e-bc3b-4c5b-bac3-9b84c67c7554',
        description: 'Remove tracking for Netflix',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(r'www\.netflix\.com')) return url.toString();
    return url.setEncodedQuery(null).toString();
  }
}

class _Pinterest extends LocalUntrackRule {
  const _Pinterest()
    : super(
        id: '21065dad-2c4c-4431-acd7-32825e831c32',
        description: 'Remove tracking for Pinterest',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(r'www\.pinterest\.com')) return url.toString();
    var u = url.setEncodedQuery(null);
    final path = u.encodedPath;
    final cleaned = path.replaceFirst(
      RegExp(r'/sent/?$', caseSensitive: false),
      '',
    );
    if (cleaned != path) u = u.setEncodedPath(cleaned);
    return u.toString();
  }
}

class _Reddit extends LocalUntrackRule {
  const _Reddit()
    : super(
        id: '67035e8c-9418-47e7-9f62-56cd30666772',
        description: 'Remove tracking for Reddit',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(r'(.+\.)?reddit\.com')) return url.toString();
    return url.retainQueryParameters('context').toString();
  }
}

class _Rednote extends LocalUntrackRule {
  const _Rednote()
    : super(
        id: '84c837db-f1c0-4738-b0ea-0f3d091885d7',
        description: 'Remove tracking for rednote',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(r'.+\.xiaohongshu\.com')) return url.toString();
    return url.retainQueryParameters('xsec_token').toString();
  }
}

class _Smzdm extends LocalUntrackRule {
  const _Smzdm()
    : super(
        id: '4244faaa-b50e-47f1-87a5-ac994c32b94f',
        description: 'Remove tracking for SMZDM',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(r'.+\.smzdm\.com')) return url.toString();
    return url.setEncodedQuery(null).toString();
  }
}

class _Spotify extends LocalUntrackRule {
  const _Spotify()
    : super(
        id: '8cbda6f2-d71d-4ee3-8ee0-05b245861c0d',
        description: 'Remove tracking for Spotify',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(r'(open\.)?spotify\.com')) return url.toString();
    return url.setEncodedQuery(null).toString();
  }
}

class _StackExchange extends LocalUntrackRule {
  const _StackExchange()
    : super(
        id: '5ed9b3ef-f4de-44c8-bd34-5c8da6e330af',
        description: 'Remove tracking for Stack Exchange sites',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(
      r'(.+\.stackexchange|askubuntu|serverfault|stackoverflow|superuser)\.com',
      r'/[aq]/[0-9]+/[0-9]+/?',
    )) {
      return url.toString();
    }
    final path = url.encodedPath;
    final cleaned = path.replaceFirst(
      RegExp(r'/[0-9]+/?$', caseSensitive: false),
      '',
    );
    return url.setEncodedPath(cleaned).toString();
  }
}

class _Taobao extends LocalUntrackRule {
  const _Taobao()
    : super(
        id: '9cb803b3-ed57-46ad-b604-8adb8c515c07',
        description: 'Remove tracking for Taobao (and Tmall)',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(r'.+\.(taobao|tmall)\.com')) return url.toString();
    return url.retainQueryParameters('id').toString();
  }
}

class _Threads extends LocalUntrackRule {
  const _Threads()
    : super(
        id: '2bce062c-7336-4ab9-bfde-7a1f9b686365',
        description: 'Remove tracking for Threads',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(r'www\.threads\.com')) return url.toString();
    return url.removeQueryParameters(r'slof|xmt').toString();
  }
}

class _TikTok extends LocalUntrackRule {
  const _TikTok()
    : super(
        id: '8420b788-c6ee-46a6-ab3b-da04d6299beb',
        description: 'Remove tracking for TikTok',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(r'.+\.tiktok\.com')) return url.toString();
    return url.setEncodedQuery(null).toString();
  }
}

class _X extends LocalUntrackRule {
  const _X()
    : super(
        id: '7a6a2ddb-a0a4-43fe-a97f-7cb74cd29ad5',
        description: 'Remove tracking for X (formerly Twitter)',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(r'(twitter|x)\.com')) return url.toString();
    return url.setEncodedQuery(null).toString();
  }
}

class _Youtube extends LocalUntrackRule {
  const _Youtube()
    : super(
        id: '88a68140-7653-4923-991d-19d1a98cd5e3',
        description: 'Remove tracking for Youtube',
      );

  @override
  String clean(TrackUrl url) {
    if (!url.matches(r'youtu\.be|((music|www)\.)?youtube\.com')) {
      return url.toString();
    }
    return url.retainQueryParameters(r'index|list|t|v').toString();
  }
}
