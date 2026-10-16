---
layout: default
title: 변경사항
description: 공개된 SIFT 버전별 주요 변경사항
permalink: /changes.html
---

# 변경사항

공개된 버전의 주요 변경사항을 모았습니다. 각 항목은 해당 버전 당시의 기록입니다.

{% assign releases = site.data.published_releases %}
{% if releases and releases.size > 0 %}
{% for release in releases %}
<section aria-labelledby="release-{{ release.tag | escape }}">
  <h2 id="release-{{ release.tag | escape }}">{{ release.tag | escape }}</h2>
  <p><time datetime="{{ release.date | escape }}">{{ release.date | escape }}</time></p>
  <p>{{ release.summary | escape }}</p>
  {% if release.details.size > 0 %}
  <details>
    <summary>자세히 보기</summary>
    <ul>
      {% for detail in release.details %}
      <li>{{ detail | escape }}</li>
      {% endfor %}
    </ul>
  </details>
  {% endif %}
</section>
{% endfor %}
{% else %}
<p>아직 공개된 버전 기록이 없습니다.</p>
{% endif %}
