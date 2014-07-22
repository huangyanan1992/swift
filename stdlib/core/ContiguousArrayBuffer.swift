//===--- ArrayBridge.swift - Array<T> <=> NSArray bridging ----------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2015 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import SwiftShims

// The empty array prototype.  We use the same object for all empty
// [Native]Array<T>s.
let emptyNSSwiftArray : _NSSwiftArray
  = reinterpretCast(_ContiguousArrayBuffer<Int>(count: 0, minimumCapacity: 0))

// The class that implements the storage for a ContiguousArray<T>
final internal class _ContiguousArrayStorage<T> : _NSSwiftArray {
  typealias Buffer = _ContiguousArrayBuffer<T>
  
  deinit {
    let b = Buffer(self)
    b.elementStorage.destroy(b.count)
    b._base._value.destroy()
  }

  final func __getInstanceSizeAndAlignMask() -> (Int,Int) {
    return Buffer(self)._base._allocatedSizeAndAlignMask()
  }

  /// Return true if the `proposedElementType` is `T` or a subclass of
  /// `T`.  We can't store anything else without violating type
  /// safety; for example, the destructor has static knowledge that
  /// all of the elements can be destroyed as `T`
  override func canStoreElementsOfDynamicType(
    proposedElementType: Any.Type
  ) -> Bool {
    return proposedElementType is T.Type
  }

  /// A type that every element in the array is.
  override var staticElementType: Any.Type {
    return T.self
  }

  /// Returns the object located at the specified index.
  override func bridgingObjectAtIndex(index: Int, _: Void = ()) -> AnyObject {
    _sanityCheck(
      !_isBridgedVerbatimToObjectiveC(T.self),
      "Verbatim bridging for objectAtIndex unhandled _NSSwiftArray")
    let b = Buffer(self)
    return _bridgeToObjectiveCUnconditional(b[index])
  }

  override func bridgingGetObjects(
    aBuffer: UnsafePointer<AnyObject>, range: _SwiftNSRange, _: Void = ()) {
    _sanityCheck(
      !_isBridgedVerbatimToObjectiveC(T.self),
      "Verbatim bridging for getObjects:range: unhandled _NSSwiftArray")
    
    let b = Buffer(self)
    let unmanagedObjects = _UnmanagedAnyObjectArray(aBuffer)
    for i in range.location..<range.location + range.length {
      let bridgedElement: AnyObject = _bridgeToObjectiveCUnconditional(b[i])
      _autorelease(bridgedElement)
      unmanagedObjects[i - range.location] = bridgedElement
    }
  }
  
  override func bridgingCountByEnumeratingWithState(
    state: UnsafePointer<_SwiftNSFastEnumerationState>,
    objects: UnsafePointer<AnyObject>, count bufferSize: Int, _: Void = ()
  ) -> Int {
    _sanityCheck(
      !_isBridgedVerbatimToObjectiveC(T.self),
      "Verbatim bridging for countByEnumeratingWithState:objects:count: unhandled _NSSwiftArray")
    
    var enumerationState = state.memory
    
    enumerationState.mutationsPtr = _fastEnumerationStorageMutationsPtr
    enumerationState.itemsPtr = AutoreleasingUnsafePointer(objects)
    
    let location = Int(enumerationState.state)
    if _fastPath(location < count) {
      let batchCount = min(bufferSize, count - location)
      
      bridgingGetObjects(
        objects, range: _SwiftNSRange(location: location, length: batchCount))
      
      enumerationState.state = UInt(location + batchCount)
      state.memory = enumerationState
      return batchCount
    }
    else {
      enumerationState.state = UInt(min(count, 1))
      return 0
    }
  }
}

public struct _ContiguousArrayBuffer<T> : _ArrayBufferType {
  
  /// Make a buffer with uninitialized elements.  After using this
  /// method, you must either initialize the count elements at the
  /// result's .elementStorage or set the result's .count to zero.
  public init(count: Int, minimumCapacity: Int)
  {
    _base = HeapBuffer(
      _ContiguousArrayStorage<T>.self,
      _ArrayBody(),
      max(count, minimumCapacity))

    var bridged = false
    if _canBeClass(T.self) {
      bridged = _isBridgedVerbatimToObjectiveC(T.self)
    }

    _base.value = _ArrayBody(count: count, capacity: _base._capacity(),  
                            elementTypeIsBridgedVerbatim: bridged)
  }

  init(_ storage: _ContiguousArrayStorage<T>?) {
    _base = reinterpretCast(storage)
  }
  
  public var hasStorage: Bool {
    return _base.hasStorage
  }

  /// If the elements are stored contiguously, a pointer to the first
  /// element. Otherwise, nil.
  public var elementStorage: UnsafePointer<T> {
    return _base.hasStorage ? _base.elementStorage : nil
  }

  /// A pointer to the first element, assuming that the elements are stored
  /// contiguously.
  var _unsafeElementStorage: UnsafePointer<T> {
    return _base.elementStorage
  }

  public func withUnsafePointerToElements<R>(body: (UnsafePointer<T>)->R) -> R {
    let p = _base.elementStorage
    return withExtendedLifetime(_base) { body(p) }
  }

  public mutating func take() -> _ContiguousArrayBuffer {
    if !_base.hasStorage {
      return _ContiguousArrayBuffer()
    }
    _sanityCheck(_base.isUniquelyReferenced(), "Can't \"take\" a shared array buffer")
    let result = self
    _base = _Base()
    return result
  }

  //===--- _ArrayBufferType conformance -----------------------------------===//
  /// The type of elements stored in the buffer
  public typealias Element = T

  /// create an empty buffer
  public init() {
    _base = HeapBuffer()
  }

  /// Adopt the storage of x
  public init(_ buffer: _ContiguousArrayBuffer) {
    self = buffer
  }
  
  public mutating func requestUniqueMutableBackingBuffer(minimumCapacity: Int)
    -> _ContiguousArrayBuffer<Element>?
  {
    return isUniquelyReferenced() && capacity >= minimumCapacity ? self : nil
  }

  public mutating func isMutableAndUniquelyReferenced() -> Bool {
    return isUniquelyReferenced()
  }
  
  /// If this buffer is backed by a _ContiguousArrayBuffer, return it.
  /// Otherwise, return nil.  Note: the result's elementStorage may
  /// not match ours, if we are a _SliceBuffer.
  public func requestNativeBuffer() -> _ContiguousArrayBuffer<Element>? {
    return self
  }
  
  /// Replace the given subRange with the first newCount elements of
  /// the given collection.
  ///
  /// Requires: this buffer is backed by a uniquely-referenced
  /// _ContiguousArrayBuffer
  public
  mutating func replace<C: CollectionType where C.Generator.Element == Element>(
    #subRange: Range<Int>, with newCount: Int, elementsOf newValues: C
  ) {
    _arrayNonSliceInPlaceReplace(&self, subRange, newCount, newValues)
  }
  
  /// Get/set the value of the ith element
  public subscript(i: Int) -> T {
    get {
      _sanityCheck(i >= 0 && i < count, "Array index out of range")
      // If the index is in bounds, we can assume we have storage.
      return _unsafeElementStorage[i]
    }
    nonmutating set {
      _sanityCheck(i >= 0 && i < count, "Array index out of range")
      // If the index is in bounds, we can assume we have storage.

      // FIXME: Manually swap because it makes the ARC optimizer happy.  See
      // <rdar://problem/16831852> check retain/release order
      // _unsafeElementStorage[i] = newValue
      var nv = newValue
      let tmp = nv
      nv = _unsafeElementStorage[i]
      _unsafeElementStorage[i] = tmp
    }
  }

  /// How many elements the buffer stores
  public var count: Int {
    get {
      return _base.hasStorage ? _base.value.count : 0
    }
    nonmutating set {
      _sanityCheck(newValue >= 0)
      
      _sanityCheck(
        newValue <= capacity,
        "Can't grow an array buffer past its capacity")

      _sanityCheck(_base.hasStorage || newValue == 0)
      
      if _base.hasStorage {
        _base.value.count = newValue
      }
    }
  }

  /// How many elements the buffer can store without reallocation
  public var capacity: Int {
    return _base.hasStorage ? _base.value.capacity : 0
  }

  /// Copy the given subRange of this buffer into uninitialized memory
  /// starting at target.  Return a pointer past-the-end of the
  /// just-initialized memory.
  public
  func _uninitializedCopy(
    subRange: Range<Int>, target: UnsafePointer<T>
  ) -> UnsafePointer<T> {
    _sanityCheck(subRange.startIndex >= 0)
    _sanityCheck(subRange.endIndex >= subRange.startIndex)
    _sanityCheck(subRange.endIndex <= count)
    
    var dst = target
    var src = elementStorage + subRange.startIndex
    for i in subRange {
      dst++.initialize(src++.memory)
    }
    _fixLifetime(owner)
    return dst
  }
  
  /// Return a _SliceBuffer containing the given subRange of values
  /// from this buffer.
  public subscript(subRange: Range<Int>) -> _SliceBuffer<T>
  {
    return _SliceBuffer(
      owner: _base.storage,
      start: elementStorage + subRange.startIndex,
      count: subRange.endIndex - subRange.startIndex,
      hasNativeBuffer: true)
  }
  
  /// Return true iff this buffer's storage is uniquely-referenced.
  /// NOTE: this does not mean the buffer is mutable.  Other factors
  /// may need to be considered, such as whether the buffer could be
  /// some immutable Cocoa container.
  public mutating func isUniquelyReferenced() -> Bool {
    return _base.isUniquelyReferenced()
  }

  /// Returns true iff this buffer is mutable. NOTE: a true result
  /// does not mean the buffer is uniquely-referenced.
  public func isMutable() -> Bool {
    return true
  }

  /// Convert to an NSArray.
  /// Precondition: T is bridged to Objective-C
  /// O(1).
  public
  func _asCocoaArray() -> _CocoaArrayType {
    _sanityCheck(
        _isBridgedToObjectiveC(T.self),
        "Array element type is not bridged to ObjectiveC")
    if count == 0 {
      return emptyNSSwiftArray
    }
    return reinterpretCast(_base.storage)
  }
  
  /// An object that keeps the elements stored in this buffer alive
  public
  var owner: AnyObject? {
    return _storage
  }

  /// A value that identifies first mutable element, if any.  Two
  /// arrays compare === iff they are both empty, or if their buffers
  /// have the same identity and count.
  public
  var identity: Word {
    return reinterpretCast(elementStorage)
  }

  /// Return true iff we have storage for elements of the given
  /// `proposedElementType`.  If not, we'll be treated as immutable.
  func canStoreElementsOfDynamicType(proposedElementType: Any.Type) -> Bool {
    if let s = _storage {
      return s.canStoreElementsOfDynamicType(proposedElementType)
    }
    return false
  }

  /// Return true if the buffer stores only elements of type `U`.
  /// Requires: `U` is a class or `@objc` existential. O(N)
  func storesOnlyElementsOfType<U>(
    _: U.Type
  ) -> Bool {
    _sanityCheck(_isClassOrObjCExistential(U.self))
    let s = _storage
    if _fastPath(s) {
      if _fastPath(s!.staticElementType is U.Type) {
        // Done in O(1)
        return true
      }
    }
    
    // Check the elements
    for x in self {
      // FIXME: reinterpretCast works around <rdar://problem/16953026>
      if !(reinterpretCast(x) as AnyObject is U) {
        return false
      }
    }
    return true
  }
  
  //===--- private --------------------------------------------------------===//
  var _storage: _ContiguousArrayStorage<T>? {
    return reinterpretCast(_base.storage)
  }
  
  typealias _Base = HeapBuffer<_ArrayBody, T>
  var _base: _Base
}

/// Append the elements of rhs to lhs
public func += <
  T, C: CollectionType where C._Element == T
> (
  inout lhs: _ContiguousArrayBuffer<T>, rhs: C
) {
  let oldCount = lhs.count
  let newCount = oldCount + numericCast(countElements(rhs))

  if _fastPath(newCount <= lhs.capacity) {
    lhs.count = newCount
    (lhs.elementStorage + oldCount).initializeFrom(rhs)
  }
  else {
    let newLHS = _ContiguousArrayBuffer<T>(
      count: newCount, 
      minimumCapacity: _growArrayCapacity(lhs.capacity))
    
    if lhs._base.hasStorage {
      newLHS.elementStorage.moveInitializeFrom(lhs.elementStorage, 
                                               count: oldCount)
      lhs._base.value.count = 0
    }
    lhs._base = newLHS._base
    (lhs._base.elementStorage + oldCount).initializeFrom(rhs)
  }
}

/// Append rhs to lhs
public func += <T> (inout lhs: _ContiguousArrayBuffer<T>, rhs: T) {
  lhs += CollectionOfOne(rhs)
}

public func === <T>(
  lhs: _ContiguousArrayBuffer<T>, rhs: _ContiguousArrayBuffer<T>
) -> Bool {
  return lhs._base == rhs._base
}

public func !== <T>(
  lhs: _ContiguousArrayBuffer<T>, rhs: _ContiguousArrayBuffer<T>
) -> Bool {
  return lhs._base != rhs._base
}

extension _ContiguousArrayBuffer : CollectionType {
  public var startIndex: Int {
    return 0
  }
  public var endIndex: Int {
    return count
  }
  public func generate() -> IndexingGenerator<_ContiguousArrayBuffer> {
    return IndexingGenerator(self)
  }
}

public func ~> <
  S: _Sequence_Type
>(
  source: S, _: (_CopyToNativeArrayBuffer,())
) -> _ContiguousArrayBuffer<S.Generator.Element>
{
  var result = _ContiguousArrayBuffer<S.Generator.Element>()

  // Using GeneratorSequence here essentially promotes the sequence to
  // a SequenceType from _Sequence_Type so we can iterate the elements
  for x in GeneratorSequence(source.generate()) {
    result += x
  }
  return result.take()
}

public func ~> <  
  C: protocol<_CollectionType,_Sequence_Type>
>(
  source: C, _:(_CopyToNativeArrayBuffer, ())
) -> _ContiguousArrayBuffer<C.Generator.Element>
{
  return _copyCollectionToNativeArrayBuffer(source)
}

internal func _copyCollectionToNativeArrayBuffer<
  C: protocol<_CollectionType,_Sequence_Type>
>(source: C) -> _ContiguousArrayBuffer<C.Generator.Element>
{
  let count = countElements(source)
  if count == 0 {
    return _ContiguousArrayBuffer()
  }
  
  var result = _ContiguousArrayBuffer<C.Generator.Element>(
    count: numericCast(count),
    minimumCapacity: 0
  )

  var p = result.elementStorage
  for x in GeneratorSequence(source.generate()) {
    (p++).initialize(x)
  }
  
  return result
}

internal protocol _ArrayType : CollectionType {
  var count: Int {get}

  typealias _Buffer : _ArrayBufferType
  var _buffer: _Buffer {get}
}
