import 'dart:async';

import 'package:build/build.dart';
import 'package:glob/glob.dart';
import 'package:gql/ast.dart';
import 'package:gql/language.dart';

import './generator.dart';
import './generator/data.dart';
import './generator/print_helpers.dart';
import './schema/options.dart';

/// [GraphQLQueryBuilder] instance, to be used by `build_runner`.
GraphQLQueryBuilder graphQLQueryBuilder(BuilderOptions options) =>
    GraphQLQueryBuilder(options);

String _addGraphQLExtensionToPathIfNeeded(String path) {
  if (!path.endsWith('.graphql.dart')) {
    return path.replaceAll(RegExp(r'\.dart$'), '.graphql.dart');
  }
  return path;
}

String _canonicalPath(String outputPath) {
  final outputParts = outputPath.split('/');
  outputParts.removeLast();
  outputParts.add('canonical.graphql.dart');

  return outputParts.join('/');
}

List<String> _builderOptionsToExpectedOutputs(BuilderOptions builderOptions) {
  final schemaMaps =
      GeneratorOptions.fromJson(builderOptions.config).schemaMapping;

  if (schemaMaps.any((s) => s.output == null)) {
    throw Exception('''One or more SchemaMap configurations miss an output!
Please check your build.yaml file.
''');
  }

  return schemaMaps
      .map((s) {
        final outputWithoutLib = s.output.replaceAll(RegExp(r'^lib/'), '');

        return {
          outputWithoutLib,
          _addGraphQLExtensionToPathIfNeeded(outputWithoutLib),
          _canonicalPath(outputWithoutLib)
        }.toList();
      })
      .expand((e) => e)
      .toList();
}

/// Main Artemis builder.
class GraphQLQueryBuilder implements Builder {
  /// Creates a builder from [BuilderOptions].
  GraphQLQueryBuilder(BuilderOptions builderOptions)
      : options = GeneratorOptions.fromJson(builderOptions.config),
        expectedOutputs = _builderOptionsToExpectedOutputs(builderOptions);

  /// This generator options, gathered from `build.yaml` file.
  final GeneratorOptions options;

  /// List FragmentDefinitionNode in fragments_glob.
  final List<FragmentDefinitionNode> fragmentsCommon = [];

  /// The generated output file.
  final List<String> expectedOutputs;

  /// Callback fired when the generator processes a [QueryDefinition].
  OnBuildQuery onBuild;

  @override
  Map<String, List<String>> get buildExtensions => {
        r'$lib$': expectedOutputs,
      };

  @override
  Future<void> build(BuildStep buildStep) async {
    if (options.fragmentsGlob != null) {
      final fragmentStream = buildStep.findAssets(Glob(options.fragmentsGlob));
      final fDocs = await fragmentStream
          .asyncMap(
            (asset) async => parseString(
              await buildStep.readAsString(asset),
              url: asset.path,
            ),
          )
          .toList();
      fDocs.forEach((fDoc) => fragmentsCommon.addAll(
          fDoc.definitions.whereType<FragmentDefinitionNode>().toList()));
    }

    final canonicalOutputFileId = AssetId(buildStep.inputId.package,
        _canonicalPath(options.schemaMapping[0].output));
    final canonicalDefinition = <String, Definition>{};

    for (final schemaMap in options.schemaMapping) {
      final buffer = StringBuffer();
      final outputFileId = AssetId(buildStep.inputId.package,
          _addGraphQLExtensionToPathIfNeeded(schemaMap.output));

      // Loop through all files in glob
      if (schemaMap.queriesGlob == null) {
        throw Exception('''No queries were considered on this generation!
Make sure that `queries_glob` your build.yaml file include GraphQL queries files.
''');
      }
      final assetStream = buildStep.findAssets(Glob(schemaMap.queriesGlob));
      final gqlDocs = await assetStream
          .asyncMap(
            (asset) async => parseString(
              await buildStep.readAsString(asset),
              url: asset.path,
            ),
          )
          .toList();

      final schemaAssetStream = buildStep.findAssets(Glob(schemaMap.schema));

      DocumentNode gqlSchema;

      try {
        gqlSchema = await schemaAssetStream
            .asyncMap(
              (asset) async => parseString(
                await buildStep.readAsString(asset),
                url: asset.path,
              ),
            )
            .first;
      } catch (e) {
        throw Exception(
            '''Schema `${schemaMap.schema}` was not found or doesn't have a proper format!
Make sure the file exists and you've typed it correctly on build.yaml.
${e}
''');
      }

      final libDefinition = generateLibrary(
        _addGraphQLExtensionToPathIfNeeded(schemaMap.output),
        gqlDocs,
        options,
        schemaMap,
        fragmentsCommon,
        gqlSchema,
      );

      if (onBuild != null) {
        onBuild(libDefinition);
      }

      final queryCanonical = <String, Definition>{};
      libDefinition.queries
          .map((e) => e.classes.map((e) => e))
          .expand((e) => e)
          .where((element) =>
              element is EnumDefinition ||
              (element is ClassDefinition && element.isInput) ||
              element is FragmentClassDefinition)
          .forEach((element) {
        queryCanonical[element.name] = element;
      });

      if (queryCanonical.isNotEmpty) {
        libDefinition.customImports.add('canonical.graphql.dart');
      }

      canonicalDefinition.addAll(queryCanonical);

      writeLibraryDefinitionToBuffer(buffer, libDefinition);

      await buildStep.writeAsString(outputFileId, buffer.toString());

      if (!schemaMap.output.endsWith('.graphql.dart')) {
        final forwarderOutputFileId =
            AssetId(buildStep.inputId.package, schemaMap.output);
        await buildStep.writeAsString(
            forwarderOutputFileId, writeLibraryForwarder(libDefinition));
      }
    }

    final canonicalBuffer = StringBuffer();
    writeCanonicalDefinitionToBuffer(canonicalBuffer, canonicalDefinition);

    await buildStep.writeAsString(
        canonicalOutputFileId, canonicalBuffer.toString());
  }
}
