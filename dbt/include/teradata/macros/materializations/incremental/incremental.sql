

{% materialization incremental, adapter='teradata' -%}

{% set unique_key = config.get('unique_key') %}

{% set target_relation = this.incorporate(type='table') %}
{% set existing_relation = load_relation(this) %}
{% set tmp_relation = make_temp_relation(this) %}

-- {#-- Validate early so we don't run SQL if the strategy is invalid --#}
{% set strategy = teradata__validate_get_incremental_strategy(config) %}

{% set on_schema_change = incremental_validate_on_schema_change(config.get('on_schema_change'), default='ignore') %}

{{ run_hooks(pre_hooks, inside_transaction=False) }}

-- `BEGIN` happens here:
{{ run_hooks(pre_hooks, inside_transaction=True) }}

{% set to_drop = [] %}
{% if existing_relation is none %}
   {% set build_sql = create_table_as(False, target_relation, sql) %}
{% elif existing_relation.is_view or should_full_refresh() %}
   {#-- Make sure the backup doesn't exist so we don't encounter issues with the rename below #}
   {% set backup_identifier = existing_relation.identifier ~ "__dbt_backup" %}
   {% set backup_relation = existing_relation.incorporate(path={"identifier": backup_identifier}) %}
   {% do adapter.drop_relation(backup_relation) %}

   {% do adapter.rename_relation(target_relation, backup_relation) %}
   {% set build_sql = create_table_as(False, target_relation, sql) %}
   {% do to_drop.append(backup_relation) %}
{% else %}
   {% set tmp_relation = make_temp_relation(target_relation) %}
   {% do run_query(create_table_as(True, tmp_relation, sql)) %}
   {% do adapter.expand_target_column_types(
          from_relation=tmp_relation,
          to_relation=target_relation) %}
   

   {% set dest_columns = process_schema_changes(on_schema_change, tmp_relation, existing_relation) %}
    {% if not dest_columns %}
        {%- set dest_columns = adapter.get_columns_in_relation(target_relation) -%}
    {% endif %}
	
	
   {% set build_sql = teradata__get_incremental_sql(strategy, target_relation, tmp_relation, unique_key, dest_columns) %}


   {% do to_drop.append(tmp_relation) %}
{% endif %}

{% call statement("main") %}
   {{ build_sql }}
{% endcall %}

-- apply grants
{%- set grant_config = config.get('grants') -%}
{% set should_revoke = should_revoke(existing_relation, full_refresh_mode) %}
{% do apply_grants(target_relation, grant_config, should_revoke) %}

{% do persist_docs(target_relation, model) %}

{{ run_hooks(post_hooks, inside_transaction=True) }}


-- `COMMIT` happens here
{% do adapter.commit() %}

{% for rel in to_drop %}
   {% do adapter.drop_relation(rel) %}
{% endfor %}

{{ run_hooks(post_hooks, inside_transaction=False) }}

{{ return({'relations': [target_relation]}) }}

{%- endmaterialization %}
