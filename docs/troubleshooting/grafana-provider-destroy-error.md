# destroy 시 "the Grafana client is required" 에러

## 증상

`Destroy (전체 인프라 삭제)` 워크플로우 실행 중 `terraform destroy` 단계에서 아래 에러가
5번 반복되고 job이 실패한다 (exit code 1).

```
Error: the Grafana client is required for this resource. Set the auth and url provider attributes
```

5번 반복되는 건 우연이 아니라 `terraform/grafana-dashboards.tf`가 만드는 Grafana 리소스
개수와 정확히 일치한다: `grafana_data_source.cloudwatch`, `grafana_folder.cloud_duck`,
`grafana_dashboard.overview` / `seoul` / `dr`.

## 원인

`provider "grafana"`는 같은 스택 안에서 만드는 서비스계정 토큰으로 인증한다.

```
aws_grafana_workspace_service_account       (워크스페이스 안의 로봇 계정)
  → aws_grafana_workspace_service_account_token   (그 계정의 API 토큰)
    → provider "grafana"                          (그 토큰으로 인증)
      → grafana_data_source / grafana_folder / grafana_dashboard
```

`terraform destroy`를 인프라 전체에 대해 한 번에 돌리면, 이 토큰 리소스도 같은 작업 안에서
삭제 대상에 포함된다. Terraform이 destroy plan을 세우는 과정에서 `provider "grafana"` 블록이
참조하는 `aws_grafana_workspace_service_account_token.tf[0].key` 값을 잃어버리고,
`grafana-dashboards.tf`의 `try(..., "")` fallback에 걸려 auth가 빈 문자열이 된다.
그 결과 grafana provider가 자체 검증에서 막힌다.

이건 `deploy.yml`에 이미 문서화되어 있던, 반대 방향(생성 시)의 문제와 대칭이다:
apply 시에는 토큰이 "아직 확정되지 않아서" 같은 에러가 났고, destroy 시에는 토큰이
"먼저 지워져서" 같은 에러가 난다. 원인 리소스(토큰)가 provider 설정을 좌우하는 한,
그 리소스를 만들거나 지우는 작업과 그 provider를 쓰는 리소스 작업이 같은 command 안에
섞이면 항상 재현 가능한 문제다.

## 언제 재현되는가

- 최초 구축 직후 바로 destroy를 돌릴 때 (apply 쪽 문제와 별개로, destroy는 항상 이 경로를 탄다)
- `enable_grafana=true`인 환경에서 전체 destroy를 실행할 때는 사실상 매번

## 해결

`deploy.yml`이 apply 방향에서 쓰는 것과 같은 패턴 — "provider가 의존하는 리소스와,
그 provider를 쓰는 리소스를 같은 terraform 명령에 섞지 않는다" — 을 destroy 방향에도
적용한다.

`destroy.yml`의 `terraform destroy`(전체) 단계 **앞**에, 토큰이 아직 살아있는 상태에서
Grafana 리소스 5개만 `-target`으로 먼저 지우는 단계를 추가했다.

```yaml
- name: Grafana 리소스 선행 destroy
  run: |
    terraform destroy -auto-approve -input=false \
      -var "image_tag_web=unused" \
      -var "image_tag_batch=unused" \
      -target=grafana_dashboard.overview \
      -target=grafana_dashboard.seoul \
      -target=grafana_dashboard.dr \
      -target=grafana_data_source.cloudwatch \
      -target=grafana_folder.cloud_duck
```

이 단계에서는 토큰 리소스가 target에 포함되지 않으므로 state에 남아있는 값 그대로
provider 인증이 성립하고, Grafana API 쪽 리소스만 먼저 정리된다. 이후 이어지는 전체
`terraform destroy`가 토큰·서비스계정·워크스페이스를 포함한 나머지를 마저 지운다.

`enable_grafana=false`이거나 이미 지워진 상태(재실행)라면 대상 리소스가 없어 "변경 없음"으로
조용히 통과한다 — deploy.yml의 토큰 선행 apply 단계와 동일한 안전장치.

커밋: `f8514a3` — `.github/workflows/destroy.yml`

## 관련 코드

- [`terraform/grafana-dashboards.tf`](../../terraform/grafana-dashboards.tf) — 문제의
  근본 원인과 apply 방향 대응이 주석으로 설명되어 있다.
- [`.github/workflows/deploy.yml`](../../.github/workflows/deploy.yml) — "Grafana 인증
  토큰 선행 apply" 단계 (같은 문제의 반대 방향 대응).
- [`.github/workflows/destroy.yml`](../../.github/workflows/destroy.yml) — "Grafana 리소스
  선행 destroy" 단계 (이 문서가 다루는 대응).

## 검증 상태

이 수정은 아직 실제 destroy 실행으로 재현·검증되지 않았다. 다음 destroy 워크플로우
실행 결과를 보고 이 문서를 갱신할 것.
