unit MVCFramework.Serializer.JSON;

interface

{$I dmvcframework.inc}


uses MVCFramework.Serializer.Intf
    , Data.DB
    , System.Rtti
    , System.SysUtils
    , System.Classes
    , MVCFramework.Serializer.Commons
    , MVCFramework.TypesAliases, MVCFramework.DuckTyping
    ;

type
  TMVCJSONSerUnSer = class(TInterfacedObject, IMVCSerUnSer)
  private
    class var CTX: TRTTIContext;
    { following methods are used internally by the serializer/unserializer to handle with the ser/unser logic }
    function SerializeFloatProperty(AObject: TObject;
      ARTTIProperty: TRttiProperty): TJSONValue; overload; deprecated;
    function SerializeFloatProperty(AElementType: TRTTIType; AValue: TValue): TJSONValue; overload;
    function SerializeFloatField(AObject: TObject; ARttiField: TRttiField): TJSONValue;
    function SerializeEnumerationProperty(AObject: TObject;
      ARTTIProperty: TRttiProperty): TJSONValue; overload; deprecated;
    function SerializeEnumerationProperty(AElementType: TRTTIType; AValue: TValue): TJSONValue; overload;
    function SerializeEnumerationField(AObject: TObject;
      ARttiField: TRttiField): TJSONValue;
    procedure DeSerializeStringStream(aStream: TStream;
      const aSerializedString: string; aEncoding: string);
    procedure DeSerializeBase64StringStream(aStream: TStream;
      const aBase64SerializedString: string);
    function ObjectToJSONObject(AObject: TObject;
      AIgnoredProperties: array of string): TJSONObject;
    function ObjectToJSONObjectFields(AObject: TObject): TJSONObject;
    function PropertyExists(JSONObject: TJSONObject;
      PropertyName: string): boolean;
    function GetPair(JSONObject: TJSONObject; PropertyName: string): TJSONPair;
    function JSONObjectToObject(Clazz: TClass;
      AJSONObject: TJSONObject): TObject;
    procedure SerializeRTTIElement(const ElementName: String; ElementType: TRTTIType;
      ElementAttributes: TArray<TCustomAttribute>; Value: TValue;
      JSONObject: TJSONObject);
  protected
    { IMVCSerializer }
    function SerializeObject(AObject: TObject;
      AIgnoredProperties: array of string): string;
    function SerializeObjectStrict(AObject: TObject): String;
    function SerializeDataSet(ADataSet: TDataSet;
      AIgnoredFields: array of string): string;
    function SerializeCollection(AList: TObject;
      AIgnoredProperties: array of string): String;
    function SerializeCollectionStrict(AList: TObject): String;
    { IMVCDeserializer }
    procedure DeserializeObject(ASerializedObject: string; AObject: TObject);
    procedure DeserializeCollection(ASerializedObjectList: string; AList: IMVCList; AClazz: TClass);
  end;

implementation

uses
  ObjectsMappers, MVCFramework.Patches, MVCFramework.RTTIUtils;

{ TMVCJSONSerializer }

procedure TMVCJSONSerUnSer.DeSerializeStringStream(aStream: TStream;
  const aSerializedString: string; aEncoding: string);
begin

end;

function TMVCJSONSerUnSer.GetPair(JSONObject: TJSONObject; PropertyName: string): TJSONPair;
var
  pair: TJSONPair;
begin
  if not Assigned(JSONObject) then
    raise EMapperException.Create('JSONObject is nil');
  pair := JSONObject.Get(PropertyName);
  Result := pair;
end;

procedure InternalJSONObjectToObject(CTX: TRTTIContext;
  AJSONObject: TJSONObject; AObject: TObject);
var
  _type: TRTTIType;
  _fields: TArray<TRttiProperty>;
  _field: TRttiProperty;
  f: string;
  jvalue: TJSONValue;
  v: TValue;
  o: TObject;
  list: IWrappedList;
  I: Integer;
  cref: TClass;
  attr: MapperItemsClassType;
  Arr: TJSONArray;
  n: TJSONNumber;
  SerStreamASString: string;
  _attrser: MapperSerializeAsString;
  ListMethod: TRttiMethod;
  ListItem: TValue;
  ListParam: TRttiParameter;
begin
  if not Assigned(AJSONObject) then
    raise EMapperException.Create('JSON Object cannot be nil');
  _type := CTX.GetType(AObject.ClassInfo);
  _fields := _type.GetProperties;
  for _field in _fields do
  begin
    if ((not _field.IsWritable) and (_field.PropertyType.TypeKind <> tkClass))
      or (TSerializerHelpers.HasAttribute<MapperTransientAttribute>(_field)) then
      Continue;
    f := TSerializerHelpers.GetKeyName(_field, _type);
    if Assigned(AJSONObject.Get(f)) then
      jvalue := AJSONObject.Get(f).JsonValue
    else
      Continue;
    case _field.PropertyType.TypeKind of
      tkEnumeration:
        begin
          if _field.PropertyType.QualifiedName = 'System.Boolean' then
          begin
            if jvalue is TJSONTrue then
              _field.SetValue(TObject(AObject), True)
            else if jvalue is TJSONFalse then
              _field.SetValue(TObject(AObject), false)
            else
              raise EMapperException.Create('Invalid value for property ' +
                _field.Name);
          end
          else // it is an enumerated value but it's not a boolean.
          begin
            TValue.Make((jvalue as TJSONNumber).AsInt,
              _field.PropertyType.Handle, v);
            _field.SetValue(TObject(AObject), v);
          end;
        end;
      tkInteger, tkInt64:
        _field.SetValue(TObject(AObject), StrToIntDef(jvalue.Value, 0));
      tkFloat:
        begin
          if _field.PropertyType.QualifiedName = 'System.TDate' then
          begin
            if jvalue is TJSONNull then
              _field.SetValue(TObject(AObject), 0)
            else
              _field.SetValue(TObject(AObject),
                ISOStrToDateTime(jvalue.Value + ' 00:00:00'))
          end
          else if _field.PropertyType.QualifiedName = 'System.TDateTime' then
          begin
            if jvalue is TJSONNull then
              _field.SetValue(TObject(AObject), 0)
            else
              _field.SetValue(TObject(AObject), ISOStrToDateTime(jvalue.Value))
          end
          else if _field.PropertyType.QualifiedName = 'System.TTime' then
          begin
            if not(jvalue is TJSONNull) then
              if jvalue is TJSONString then
                _field.SetValue(TObject(AObject), ISOStrToTime(jvalue.Value))
              else
                raise EMapperException.CreateFmt
                  ('Cannot deserialize [%s], expected [%s] got [%s]',
                  [_field.Name, 'TJSONString', jvalue.ClassName]);
          end
          else { if _field.PropertyType.QualifiedName = 'System.Currency' then }
          begin
            if not(jvalue is TJSONNull) then
              if jvalue is TJSONNumber then
                _field.SetValue(TObject(AObject), TJSONNumber(jvalue).AsDouble)
              else
                raise EMapperException.CreateFmt
                  ('Cannot deserialize [%s], expected [%s] got [%s]',
                  [_field.Name, 'TJSONNumber', jvalue.ClassName]);
          end {
            else
            begin
            _field.SetValue(TObject(AObject), (jvalue as TJSONNumber).AsDouble)
            end; }
        end;
      tkString, tkLString, tkWString, tkUString:
        begin
          _field.SetValue(TObject(AObject), jvalue.Value);
        end;
      tkRecord:
        begin
          if _field.PropertyType.QualifiedName = 'System.SysUtils.TTimeStamp'
          then
          begin
            n := jvalue as TJSONNumber;
            _field.SetValue(TObject(AObject),
              TValue.From<TTimeStamp>(MSecsToTimeStamp(n.AsInt64)));
          end;
        end;
      tkClass: // try to restore child properties... but only if the collection is not nil!!!
        begin
          o := _field.GetValue(TObject(AObject)).AsObject;
          if Assigned(o) then
          begin
            if jvalue is TJSONNull then
            begin
              FreeAndNil(o);
              _field.SetValue(AObject, nil);
            end
            else if o is TStream then
            begin
              if jvalue is TJSONString then
              begin
                SerStreamASString := TJSONString(jvalue).Value;
              end
              else
                raise EMapperException.Create('Expected JSONString in ' +
                  AJSONObject.Get(f).JsonString.Value);

              if TSerializerHelpers.HasAttribute<MapperSerializeAsString>(_field, _attrser) then
              begin
                TSerializerHelpers.DeSerializeStringStream(TStream(o), SerStreamASString,
                  _attrser.Encoding);
              end
              else
              begin
                TSerializerHelpers.DeSerializeBase64StringStream(TStream(o), SerStreamASString);
              end;
            end
            else if TDuckTypedList.CanBeWrappedAsList(o) then
            begin // restore collection
              if jvalue is TJSONArray then
              begin
                Arr := TJSONArray(jvalue);
                // look for the MapperItemsClassType on the property itself or on the property type
                if Mapper.HasAttribute<MapperItemsClassType>(_field, attr) or
                  Mapper.HasAttribute<MapperItemsClassType>(_field.PropertyType,
                  attr) then
                begin
                  cref := attr.Value;
                  list := WrapAsList(o);
                  for I := 0 to Arr.Count - 1 do
                  begin
                    list.Add(Mapper.JSONObjectToObject(cref,
                      Arr.Items[I] as TJSONObject));
                  end;
                end
                else // Ezequiel J. M�ller convert regular list
                begin
                  ListMethod := CTX.GetType(o.ClassInfo).GetMethod('Add');
                  if (ListMethod <> nil) then
                  begin
                    for I := 0 to Arr.Count - 1 do
                    begin
                      ListItem := TValue.Empty;

                      for ListParam in ListMethod.GetParameters do
                        case ListParam.ParamType.TypeKind of
                          tkInteger, tkInt64:
                            ListItem := StrToIntDef(Arr.Items[I].Value, 0);
                          tkFloat:
                            ListItem := TJSONNumber(Arr.Items[I].Value).AsDouble;
                          tkString, tkLString, tkWString, tkUString:
                            ListItem := Arr.Items[I].Value;
                        end;

                      if not ListItem.IsEmpty then
                        ListMethod.Invoke(o, [ListItem]);
                    end;
                  end;
                end;
              end
              else
                raise EMapperException.Create('Cannot restore ' + f +
                  ' because the related json property is not an array');
            end
            else // try to deserialize into the property... but the json MUST be an object
            begin
              if jvalue is TJSONObject then
              begin
                InternalJSONObjectToObject(CTX, TJSONObject(jvalue), o);
              end
              else if jvalue is TJSONNull then
              begin
                FreeAndNil(o);
                _field.SetValue(AObject, nil);
              end
              else
                raise EMapperException.Create('Cannot deserialize property ' +
                  _field.Name);
            end;
          end;
        end;
    end;
  end;
end;

function TMVCJSONSerUnSer.JSONObjectToObject(Clazz: TClass; AJSONObject: TJSONObject): TObject;
var
  AObject: TObject;
begin
  AObject := TRTTIUtils.CreateObject(Clazz.QualifiedClassName);
  try
    InternalJSONObjectToObject(CTX, AJSONObject, AObject);
    Result := AObject;
  except
    on E: Exception do
    begin
      FreeAndNil(AObject);
      raise EMVCDeserializationException.Create(E.Message);
    end;
  end;
end;

function TMVCJSONSerUnSer.ObjectToJSONObject(AObject: TObject;
  AIgnoredProperties: array of string): TJSONObject;
var
  lType: TRTTIType;
  lProperties: TArray<TRttiProperty>;
  lProperty: TRttiProperty;
  f: string;
  JSONObject: TJSONObject;
  Arr: TJSONArray;
  list: IMVCList;
  Obj, o: TObject;
  DoNotSerializeThis: boolean;
  I: Integer;
  ThereAreIgnoredProperties: boolean;
  ts: TTimeStamp;
  sr: TStringStream;
  SS: TStringStream;
  _attrser: MapperSerializeAsString;
  SerEnc: TEncoding;
begin
  ThereAreIgnoredProperties := Length(AIgnoredProperties) > 0;
  JSONObject := TJSONObject.Create;
  lType := CTX.GetType(AObject.ClassInfo);
  lProperties := lType.GetProperties;
  for lProperty in lProperties do
  begin
    // f := LowerCase(_property.Name);
    f := TSerializerHelpers.GetKeyName(lProperty, lType);
    // Delete(f, 1, 1);
    if ThereAreIgnoredProperties then
    begin
      DoNotSerializeThis := false;
      for I := low(AIgnoredProperties) to high(AIgnoredProperties) do
        if SameText(f, AIgnoredProperties[I]) then
        begin
          DoNotSerializeThis := True;
          Break;
        end;
      if DoNotSerializeThis then
        Continue;
    end;

    if TSerializerHelpers.HasAttribute<DoNotSerializeAttribute>(lProperty) then
      Continue;
    SerializeRTTIElement(f, lProperty.PropertyType, lProperty.GetAttributes, lProperty.GetValue(AObject), JSONObject);
  end;
  Result := JSONObject;

end;

function TMVCJSONSerUnSer.ObjectToJSONObjectFields(AObject: TObject): TJSONObject;
var
  _type: TRTTIType;
  _fields: TArray<TRttiField>;
  _field: TRttiField;
  f: string;
  JSONObject: TJSONObject;
  Arr: TJSONArray;
  list: IWrappedList;
  Obj, o: TObject;
  DoNotSerializeThis: boolean;
  I: Integer;
  JObj: TJSONObject;
begin
  JSONObject := TJSONObject.Create;
  try
    // add the $dmvc.classname property to allows a strict deserialization
    JSONObject.AddPair(DMVC_CLASSNAME, AObject.QualifiedClassName);
    _type := CTX.GetType(AObject.ClassInfo);
    _fields := _type.GetFields;
    for _field in _fields do
    begin
      f := TSerializerHelpers.GetKeyName(_field, _type);
      SerializeRTTIElement(f, _field.FieldType, _field.GetAttributes, _field.GetValue(AObject), JSONObject);

      // case _field.FieldType.TypeKind of
      // tkInteger, tkInt64:
      // JSONObject.AddPair(f, TJSONNumber.Create(_field.GetValue(AObject)
      // .AsInteger));
      // tkFloat:
      // begin
      // JSONObject.AddPair(f, SerializeFloatField(AObject, _field));
      // end;
      // tkString, tkLString, tkWString, tkUString:
      // JSONObject.AddPair(f, _field.GetValue(AObject).AsString);
      // tkEnumeration:
      // begin
      // JSONObject.AddPair(f, SerializeEnumerationField(AObject, _field));
      // end;
      // tkClass:
      // begin
      // o := _field.GetValue(AObject).AsObject;
      // if Assigned(o) then
      // begin
      // if TDuckTypedList.CanBeWrappedAsList(o) then
      // begin
      // list := WrapAsList(o);
      // JObj := TJSONObject.Create;
      // JSONObject.AddPair(f, JObj);
      // JObj.AddPair(DMVC_CLASSNAME, o.QualifiedClassName);
      // Arr := TJSONArray.Create;
      // JObj.AddPair('items', Arr);
      // for Obj in list do
      // begin
      // Arr.AddElement(ObjectToJSONObjectFields(Obj));
      // end;
      // end
      // else
      // begin
      // JSONObject.AddPair(f,
      // ObjectToJSONObjectFields(_field.GetValue(AObject).AsObject));
      // end;
      // end
      // else
      // JSONObject.AddPair(f, TJSONNull.Create);
      // end;
      // end;
    end;
    Result := JSONObject;
  except
    FreeAndNil(JSONObject);
    raise;
  end;
end;

function TMVCJSONSerUnSer.SerializeFloatProperty(AObject: TObject;
  ARTTIProperty: TRttiProperty): TJSONValue;
begin
  if ARTTIProperty.PropertyType.QualifiedName = 'System.TDate' then
  begin
    if ARTTIProperty.GetValue(AObject).AsExtended = 0 then
      Result := TJSONNull.Create
    else
      Result := TJSONString.Create
        (ISODateToString(ARTTIProperty.GetValue(AObject).AsExtended))
  end
  else if ARTTIProperty.PropertyType.QualifiedName = 'System.TDateTime' then
  begin
    if ARTTIProperty.GetValue(AObject).AsExtended = 0 then
      Result := TJSONNull.Create
    else
      Result := TJSONString.Create
        (ISODateTimeToString(ARTTIProperty.GetValue(AObject).AsExtended))
  end
  else if ARTTIProperty.PropertyType.QualifiedName = 'System.TTime' then
    Result := TJSONString.Create(ISOTimeToString(ARTTIProperty.GetValue(AObject)
      .AsExtended))
  else
    Result := TJSONNumber.Create(ARTTIProperty.GetValue(AObject).AsExtended);
end;

function TMVCJSONSerUnSer.SerializeObject(AObject: TObject;
  AIgnoredProperties: array of string): string;
var
  lJSON: TJSONObject;
begin
  lJSON := ObjectToJSONObject(AObject, AIgnoredProperties);
  try
    Result := lJSON.ToJSON;
  finally
    lJSON.Free;
  end;
end;

function TMVCJSONSerUnSer.SerializeObjectStrict(AObject: TObject): String;
begin

end;

procedure TMVCJSONSerUnSer.SerializeRTTIElement(const ElementName: String; ElementType: TRTTIType;
  ElementAttributes: TArray<TCustomAttribute>; Value: TValue;
  JSONObject: TJSONObject);
var
  ts: TTimeStamp;
  o: TObject;
  list: IMVCList;
  Arr: TJSONArray;
  Obj: TObject;
  _attrser: MapperSerializeAsString;
  SerEnc: TEncoding;
  sr: TStringStream;
  SS: TStringStream;
  lAttribute: MapperSerializeAsString;
  lAtt: TCustomAttribute;
  lEncodingName: string;
  buff: TBytes;
  lStreamAsString: string;
begin
  case ElementType.TypeKind of
    tkInteger, tkInt64:
      JSONObject.AddPair(ElementName, TJSONNumber.Create(Value.AsInteger));
    tkFloat:
      begin
        JSONObject.AddPair(ElementName, SerializeFloatProperty(ElementType, Value));
      end;
    tkString, tkLString, tkWString, tkUString:
      JSONObject.AddPair(ElementName, Value.AsString);
    tkEnumeration:
      begin
        JSONObject.AddPair(ElementName, SerializeEnumerationProperty(ElementType, Value));
      end;
    tkRecord:
      begin
        if ElementType.QualifiedName = 'System.SysUtils.TTimeStamp'
        then
        begin
          ts := Value.AsType<System.SysUtils.TTimeStamp>;
          JSONObject.AddPair(ElementName, TJSONNumber.Create(TimeStampToMsecs(ts)));
        end;
      end;
    tkClass:
      begin
        o := Value.AsObject;
        if Assigned(o) then
        begin
          list := TDuckTypedList.Wrap(o);
          if Assigned(list) then
          begin
            Arr := TJSONArray.Create;
            JSONObject.AddPair(ElementName, Arr);
            for Obj in list do
              if Assigned(Obj) then
                // nil element into the list are not serialized
                Arr.AddElement(ObjectToJSONObject(Obj, []));
          end
          else if o is TStream then
          begin
            if TSerializerHelpers.AttributeExists<MapperSerializeAsString>(ElementAttributes, _attrser) then
            begin
              // serialize the stream as a normal string...
              TStream(o).Position := 0;
              lEncodingName := _attrser.Encoding;
              SerEnc := TEncoding.GetEncoding(lEncodingName);
              try
                SetLength(buff, TStream(o).Size);
                TStream(o).Read(buff, TStream(o).Size);
                lStreamAsString := SerEnc.GetString(buff);
                SetLength(buff, 0);
                JSONObject.AddPair(ElementName, UTF8Encode(lStreamAsString));
              finally
                SerEnc.Free;
              end;
            end
            else
            begin
              // serialize the stream as Base64 encoded string...
              TStream(o).Position := 0;
              SS := TStringStream.Create;
              try
                TSerializerHelpers.EncodeStream(TStream(o), SS);
                JSONObject.AddPair(ElementName, SS.DataString);
              finally
                SS.Free;
              end;
            end;
          end
          else
          begin
            JSONObject.AddPair(ElementName,
              ObjectToJSONObject(Value.AsObject, []));
          end;
        end
        else
        begin
          if TSerializerHelpers.HasAttribute<MapperSerializeAsString>(ElementType) then
            JSONObject.AddPair(ElementName, '')
          else
            JSONObject.AddPair(ElementName, TJSONNull.Create);
        end;
      end; // tkClass
  end;
end;

function TMVCJSONSerUnSer.SerializeCollection(AList: TObject;
  AIgnoredProperties: array of string): String;
var
  I: Integer;
  JV: TJSONObject;
  lList: IMVCList;
  lJArr: TJSONArray;
begin
  if Assigned(AList) then
  begin
    lList := WrapAsList(AList);
    lJArr := TJSONArray.Create;
    try
      // AList.OwnsObjects := AOwnsChildObjects;
      for I := 0 to lList.Count - 1 do
      begin
        JV := ObjectToJSONObject(lList.GetItem(I), AIgnoredProperties);
        // if Assigned(AForEach) then
        // AForEach(JV);
        lJArr.AddElement(JV);
      end;
      Result := lJArr.ToJSON;
    finally
      lJArr.Free;
    end;
  end
  else
  begin
    raise EMVCSerializationException.Create('List is nil');
  end;
end;

function TMVCJSONSerUnSer.SerializeCollectionStrict(AList: TObject): String;
var
  I: Integer;
  JV: TJSONObject;
  lList: IMVCList;
  lJArr: TJSONArray;
begin
  if Assigned(AList) then
  begin
    lList := WrapAsList(AList);
    lJArr := TJSONArray.Create;
    try
      for I := 0 to lList.Count - 1 do
      begin
        JV := ObjectToJSONObjectFields(lList.GetItem(I));
        // if Assigned(AForEach) then
        // AForEach(JV);
        lJArr.AddElement(JV);
      end;
      Result := lJArr.ToJSON;
    finally
      lJArr.Free;
    end;
  end
  else
  begin
    raise EMVCSerializationException.Create('List is nil');
  end;
end;

function TMVCJSONSerUnSer.PropertyExists(JSONObject: TJSONObject;
  PropertyName: string): boolean;
begin
  Result := Assigned(GetPair(JSONObject, PropertyName));
end;

function TMVCJSONSerUnSer.SerializeDataSet(ADataSet: TDataSet;
  AIgnoredFields: array of string): string;
begin

end;

function TMVCJSONSerUnSer.SerializeEnumerationField(AObject: TObject;
  ARttiField: TRttiField): TJSONValue;
begin
  if ARttiField.FieldType.QualifiedName = 'System.Boolean' then
  begin
    if ARttiField.GetValue(AObject).AsBoolean then
      Result := TJSONTrue.Create
    else
      Result := TJSONFalse.Create;
  end
  else
  begin
    Result := TJSONNumber.Create(ARttiField.GetValue(AObject).AsOrdinal);
  end;
end;

function TMVCJSONSerUnSer.SerializeEnumerationProperty(AElementType: TRTTIType;
  AValue: TValue): TJSONValue;
begin
  if AElementType.QualifiedName = 'System.Boolean' then
  begin
    if AValue.AsBoolean then
      Result := TJSONTrue.Create
    else
      Result := TJSONFalse.Create;
  end
  else
  begin
    Result := TJSONNumber.Create(AValue.AsOrdinal);
  end;
end;

function TMVCJSONSerUnSer.SerializeEnumerationProperty(AObject: TObject;
  ARTTIProperty: TRttiProperty): TJSONValue;
begin
  if ARTTIProperty.PropertyType.QualifiedName = 'System.Boolean' then
  begin
    if ARTTIProperty.GetValue(AObject).AsBoolean then
      Result := TJSONTrue.Create
    else
      Result := TJSONFalse.Create;
  end
  else
  begin
    Result := TJSONNumber.Create(ARTTIProperty.GetValue(AObject).AsOrdinal);
  end;
end;

function TMVCJSONSerUnSer.SerializeFloatField(AObject: TObject;
  ARttiField: TRttiField): TJSONValue;
begin
  if ARttiField.FieldType.QualifiedName = 'System.TDate' then
  begin
    if ARttiField.GetValue(AObject).AsExtended = 0 then
      Result := TJSONNull.Create
    else
      Result := TJSONString.Create(ISODateToString(ARttiField.GetValue(AObject)
        .AsExtended))
  end
  else if ARttiField.FieldType.QualifiedName = 'System.TDateTime' then
  begin
    if ARttiField.GetValue(AObject).AsExtended = 0 then
      Result := TJSONNull.Create
    else
      Result := TJSONString.Create
        (ISODateTimeToString(ARttiField.GetValue(AObject).AsExtended))
  end
  else if ARttiField.FieldType.QualifiedName = 'System.TTime' then
    Result := TJSONString.Create(ISOTimeToString(ARttiField.GetValue(AObject)
      .AsExtended))
  else
    Result := TJSONNumber.Create(ARttiField.GetValue(AObject).AsExtended);
end;

function TMVCJSONSerUnSer.SerializeFloatProperty(AElementType: TRTTIType;
  AValue: TValue): TJSONValue;
begin
  if AElementType.QualifiedName = 'System.TDate' then
  begin
    if AValue.AsExtended = 0 then
      Result := TJSONNull.Create
    else
      Result := TJSONString.Create
        (ISODateToString(AValue.AsExtended))
  end
  else if AElementType.QualifiedName = 'System.TDateTime' then
  begin
    if AValue.AsExtended = 0 then
      Result := TJSONNull.Create
    else
      Result := TJSONString.Create
        (ISODateTimeToString(AValue.AsExtended))
  end
  else if AElementType.QualifiedName = 'System.TTime' then
    Result := TJSONString.Create(ISOTimeToString(AValue.AsExtended))
  else
    Result := TJSONNumber.Create(AValue.AsExtended);
end;

{ TMVCJSONDeserializer }

procedure TMVCJSONSerUnSer.DeserializeCollection(ASerializedObjectList: string; AList: IMVCList; AClazz: TClass);
var
  I: Integer;
  lJArr: TJSONArray;
  lJValue: TJSONValue;
begin
  if Trim(ASerializedObjectList) = '' then
    raise EMVCDeserializationException.Create('Invalid serialized data');
  lJValue := TJSONObject.ParseJSONValue(ASerializedObjectList);
  try
    if (lJValue = nil) or (not(lJValue is TJSONArray)) then
      raise EMVCDeserializationException.Create('Serialized data is not a valid JSON Array');
    lJArr := TJSONArray(lJValue);
    for I := 0 to lJArr.Count - 1 do
    begin
      AList.Add(JSONObjectToObject(AClazz, lJArr.Items[I] as TJSONObject));
    end;
  finally
    lJValue.Free;
  end;
end;

procedure TMVCJSONSerUnSer.DeSerializeBase64StringStream(aStream: TStream;
  const aBase64SerializedString: string);
begin

end;

procedure TMVCJSONSerUnSer.DeserializeObject(ASerializedObject: string; AObject: TObject);
var
  lJSON: TJSONValue;
begin
  lJSON := TJSONObject.ParseJSONValue(ASerializedObject);
  try
    if lJSON <> nil then
    begin
      if lJSON is TJSONObject then
      begin
        InternalJSONObjectToObject(CTX, TJSONObject(lJSON), AObject)
      end
      else
      begin
        raise EMVCDeserializationException.CreateFmt('Serialized string is a %s, expected JSON Object',
          [lJSON.ClassName]);
      end;
    end
    else
    begin
      raise EMVCDeserializationException.Create('Serialized string is not a valid JSON');
    end;
  finally
    lJSON.Free;
  end;
end;

initialization

TMVCSerUnSerRegistry.RegisterSerializer('application/json', TMVCJSONSerUnSer.Create);

finalization

TMVCSerUnSerRegistry.UnRegisterSerializer('application/json');

end.
