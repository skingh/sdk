// Copyright (c) 2020, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/src/dart/element/element.dart';
import 'package:analyzer/src/dart/element/type_algebra.dart';
import 'package:analyzer/src/dart/element/type_system.dart';
import 'package:meta/meta.dart';

class ClassHierarchy {
  final Map<ClassElement, _Hierarchy> _map = {};

  List<ClassHierarchyError> errors(ClassElement element) {
    return _getHierarchy(element).errors;
  }

  List<InterfaceType> implementedInterfaces(ClassElement element) {
    return _getHierarchy(element).interfaces;
  }

  void remove(ClassElement element) {
    _map.remove(element);
  }

  /// Remove hierarchies for classes defined in specified libraries.
  void removeOfLibraries(Set<String> uriStrSet) {
    _map.removeWhere((element, _) {
      var uriStr = '${element.librarySource.uri}';
      return uriStrSet.contains(uriStr);
    });
  }

  _Hierarchy _getHierarchy(ClassElement element) {
    var hierarchy = _map[element];

    if (hierarchy != null) {
      return hierarchy;
    }

    hierarchy = _Hierarchy(
      errors: const <ClassHierarchyError>[],
      interfaces: const <InterfaceType>[],
    );
    _map[element] = hierarchy;

    var library = element.library as LibraryElementImpl;
    var typeSystem = library.typeSystem;
    var map = <ClassElement, _ClassInterfaceType>{};

    void appendOne(InterfaceType type) {
      var element = type.element;
      var classResult = map[element];
      if (classResult == null) {
        classResult = _ClassInterfaceType(typeSystem);
        map[element] = classResult;
      }
      classResult.update(type);
    }

    void append(InterfaceType type) {
      if (type == null) {
        return;
      }

      appendOne(type);

      var substitution = Substitution.fromInterfaceType(type);
      var rawInterfaces = implementedInterfaces(type.element);
      for (var rawInterface in rawInterfaces) {
        var newInterface = substitution.substituteType(rawInterface);
        newInterface = library.toLegacyTypeIfOptOut(newInterface);
        appendOne(newInterface);
      }
    }

    append(element.supertype);
    for (var type in element.superclassConstraints) {
      append(type);
    }
    for (var type in element.interfaces) {
      append(type);
    }
    for (var type in element.mixins) {
      append(type);
    }

    var errors = <ClassHierarchyError>[];
    var interfaces = <InterfaceType>[];
    for (var collector in map.values) {
      if (collector._error != null) {
        errors.add(collector._error);
      }
      interfaces.add(collector.type);
    }

    hierarchy.errors = errors;
    hierarchy.interfaces = interfaces;

    return hierarchy;
  }
}

abstract class ClassHierarchyError {}

/// This error is recorded when the same generic class is found in the
/// hierarchy of a class, and the type arguments are not compatible. What it
/// means to be compatible depends on whether the class is declared in a
/// legacy, or an opted-in library.
///
/// In legacy libraries LEGACY_ERASURE of the interfaces must be syntactically
/// equal.
///
/// In opted-in libraries NNBD_TOP_MERGE of NORM of the interfaces must be
/// successful.
class IncompatibleInterfacesClassHierarchyError extends ClassHierarchyError {
  final InterfaceType first;
  final InterfaceType second;

  IncompatibleInterfacesClassHierarchyError(this.first, this.second);
}

class _ClassInterfaceType {
  final TypeSystemImpl _typeSystem;

  ClassHierarchyError _error;

  InterfaceType _singleType;
  InterfaceType _currentResult;

  _ClassInterfaceType(this._typeSystem);

  InterfaceType get type => _currentResult ?? _singleType;

  void update(InterfaceType type) {
    if (_error != null) {
      return;
    }

    if (_typeSystem.isNonNullableByDefault) {
      if (_currentResult == null) {
        if (_singleType == null) {
          _singleType = type;
          return;
        } else if (type == _singleType) {
          return;
        } else {
          _currentResult = _typeSystem.normalize(_singleType);
        }
      }

      var normType = _typeSystem.normalize(type);
      try {
        _currentResult = _typeSystem.topMerge(_currentResult, normType);
      } catch (e) {
        _error = IncompatibleInterfacesClassHierarchyError(
          _currentResult,
          type,
        );
      }
    } else {
      var legacyType = _typeSystem.toLegacyType(type);
      if (_currentResult == null) {
        _currentResult = legacyType;
      } else {
        if (legacyType != _currentResult) {
          _error = IncompatibleInterfacesClassHierarchyError(
            _currentResult,
            legacyType,
          );
        }
      }
    }
  }
}

class _Hierarchy {
  List<ClassHierarchyError> errors;
  List<InterfaceType> interfaces;

  _Hierarchy({
    @required this.errors,
    @required this.interfaces,
  });
}
