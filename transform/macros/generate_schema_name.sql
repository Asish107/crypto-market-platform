{#
  dbt's default is to PREFIX the target dataset onto any custom schema, so a
  model with +schema: marts and a target dataset of `staging` lands in
  `staging_marts`. That default exists so several developers can share a
  warehouse without colliding.

  Here the datasets are Terraform-managed with their own IAM and expiry
  policies (raw, staging, intermediate, marts, ci), so a model configured for
  `marts` must land in `marts` and nowhere else. Isolation between developers
  is handled by the CI dataset instead.
#}
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- elif target.name == 'ci' -%}
        {#- Slim CI writes everything into one throwaway dataset with a 24h
            table expiry, so a failed PR cannot leave debris in real ones. -#}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
