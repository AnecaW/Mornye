import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:material_3_expressive/material_3_expressive.dart';
import 'package:mornye/theme/material_expressive.dart';
import 'package:mornye/widgets/ios_system_view.dart';

/// Text input for Material dialogs, sheets and settings. Expressive builds use
/// the M3E text field; Mornye and reduced motion keep the plain field with
/// [decoration], so their existing look is unchanged.
///
/// Inputs that disable autocorrect stay on plain fields because the M3E field
/// cannot honor that option. Credentials also keep their dedicated fields.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    this.controller,
    this.label,
    this.hint,
    this.leading,
    this.errorText,
    this.decoration,
    this.keyboardType,
    this.textInputAction,
    this.inputFormatters,
    this.maxLines = 1,
    this.maxLength,
    this.autofocus = false,
    this.outlined = false,
    this.onChanged,
    this.onSubmitted,
    this.validator,
    this.scrollPadding = const EdgeInsets.all(20),
    this.autocorrect = true,
    this.forcePlain = false,
    this.enabled = true,
    this.obscureText = false,
    this.enableSuggestions = true,
    this.enableIMEPersonalizedLearning = true,
    this.focusNode,
    this.minLines,
    this.scrollPhysics,
    this.autofillHints,
    this.textAlign = TextAlign.start,
    this.textCapitalization = TextCapitalization.none,
    this.style,
    this.cursorColor,
  });

  final TextEditingController? controller;
  final String? label;
  final String? hint;
  final Widget? leading;
  final String? errorText;

  /// Plain-field decoration. Defaults to [label], [hint], [leading] and
  /// [errorText] on the theme's input decoration.
  final InputDecoration? decoration;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final List<TextInputFormatter>? inputFormatters;
  final int? maxLines;
  final int? maxLength;
  final bool autofocus;

  /// Outlined rather than filled container in the expressive style.
  final bool outlined;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  /// Validates inside an enclosing [Form], like [TextFormField].
  final FormFieldValidator<String>? validator;

  /// Keyboard reveal margin of the plain field.
  final EdgeInsets scrollPadding;

  /// False keeps the plain field so keyboard correction stays disabled.
  final bool autocorrect;
  final bool forcePlain;
  final bool enabled;
  final bool obscureText;
  final bool enableSuggestions;
  final bool enableIMEPersonalizedLearning;
  final FocusNode? focusNode;
  final int? minLines;
  final ScrollPhysics? scrollPhysics;
  final Iterable<String>? autofillHints;
  final TextAlign textAlign;
  final TextCapitalization textCapitalization;
  final TextStyle? style;
  final Color? cursorColor;

  @override
  Widget build(BuildContext context) {
    if (usesIosVisualStyle) {
      return validator == null
          ? _IosTextInput(field: this)
          : _ExpressiveTextFormField(field: this);
    }
    if (forcePlain || !materialExpressiveEnabled(context) || !autocorrect) {
      return _plainField();
    }
    if (validator != null) return _ExpressiveTextFormField(field: this);
    return _expressiveField();
  }

  Widget _expressiveField({
    TextEditingController? fieldController,
    String? formError,
    ValueChanged<String>? onChanged,
  }) => MaterialExpressiveScope(
    child: M3ETextField(
      // The dependency retains its initial controller for its lifetime.
      key: ObjectKey(fieldController ?? controller),
      controller: fieldController ?? controller,
      label: label,
      placeholder: hint,
      leading: leading,
      errorText: formError ?? errorText,
      variant: outlined
          ? M3ETextFieldVariant.outlined
          : M3ETextFieldVariant.filled,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      inputFormatters: inputFormatters,
      maxLines: maxLines,
      maxLength: maxLength,
      autofocus: autofocus,
      onChanged: onChanged ?? this.onChanged,
      onSubmitted: onSubmitted,
    ),
  );

  Widget _plainField() {
    final decoration =
        this.decoration ??
        InputDecoration(
          labelText: label,
          hintText: hint,
          prefixIcon: leading,
          errorText: errorText,
        );
    if (validator != null) {
      return TextFormField(
        controller: controller,
        focusNode: focusNode,
        enabled: enabled,
        obscureText: obscureText,
        enableSuggestions: enableSuggestions,
        enableIMEPersonalizedLearning: enableIMEPersonalizedLearning,
        autofillHints: autofillHints,
        textAlign: textAlign,
        textCapitalization: textCapitalization,
        style: style,
        cursorColor: cursorColor,
        scrollPhysics: scrollPhysics,
        decoration: decoration,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        inputFormatters: inputFormatters,
        maxLines: maxLines,
        minLines: minLines,
        maxLength: maxLength,
        autofocus: autofocus,
        onChanged: onChanged,
        onFieldSubmitted: onSubmitted,
        validator: validator,
        scrollPadding: scrollPadding,
        autocorrect: autocorrect,
      );
    }
    return TextField(
      controller: controller,
      focusNode: focusNode,
      enabled: enabled,
      obscureText: obscureText,
      enableSuggestions: enableSuggestions,
      enableIMEPersonalizedLearning: enableIMEPersonalizedLearning,
      autofillHints: autofillHints,
      textAlign: textAlign,
      textCapitalization: textCapitalization,
      style: style,
      cursorColor: cursorColor,
      scrollPhysics: scrollPhysics,
      decoration: decoration,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      inputFormatters: inputFormatters,
      maxLines: maxLines,
      minLines: minLines,
      maxLength: maxLength,
      autofocus: autofocus,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      scrollPadding: scrollPadding,
      autocorrect: autocorrect,
    );
  }
}

class _ExpressiveTextFormField extends FormField<String> {
  _ExpressiveTextFormField({required this.field})
    : super(
        initialValue: field.controller?.text ?? '',
        validator: field.validator,
        enabled: field.enabled,
        builder: (state) {
          final controller =
              (state as _ExpressiveTextFormFieldState)._controller;
          void changed(String value) {
            if (state.value != value) state.didChange(value);
            field.onChanged?.call(value);
          }

          if (usesIosVisualStyle) {
            return _IosTextInput(
              field: field,
              formController: controller,
              formError: state.errorText,
              onChanged: changed,
            );
          }
          return field._expressiveField(
            fieldController: controller,
            formError: state.errorText,
            onChanged: changed,
          );
        },
      );

  final AppTextField field;

  @override
  FormFieldState<String> createState() => _ExpressiveTextFormFieldState();
}

/// Keep InputDecorator's label, accessory and validation slots while using
/// Cupertino editing, selection and keyboard behavior inside those slots.
class _IosTextInput extends StatefulWidget {
  const _IosTextInput({
    required this.field,
    this.formController,
    this.formError,
    this.onChanged,
  });

  final AppTextField field;
  final TextEditingController? formController;
  final String? formError;
  final ValueChanged<String>? onChanged;

  @override
  State<_IosTextInput> createState() => _IosTextInputState();
}

class _IosTextInputState extends State<_IosTextInput> {
  final _localController = TextEditingController();
  final _focus = FocusNode();

  @override
  Widget build(BuildContext context) {
    final field = widget.field;
    final focus = field.focusNode ?? _focus;
    final controller =
        widget.formController ?? field.controller ?? _localController;
    final style = field.style ?? Theme.of(context).textTheme.bodyLarge;
    final decoration =
        field.decoration ??
        InputDecoration(
          labelText: field.label,
          hintText: field.hint,
          prefixIcon: field.leading,
          errorText: field.errorText,
        );
    return ListenableBuilder(
      listenable: Listenable.merge([controller, focus]),
      builder: (context, child) => InputDecorator(
        decoration: decoration.copyWith(
          errorText: widget.formError ?? decoration.errorText,
          enabled: field.enabled,
          counterText:
              decoration.counterText ??
              (field.maxLength == null
                  ? null
                  : '${controller.text.characters.length}/${field.maxLength}'),
        ),
        isFocused: focus.hasFocus,
        isEmpty: controller.text.isEmpty,
        baseStyle: style,
        child: child,
      ),
      child: CupertinoTextField(
        controller: controller,
        focusNode: focus,
        enabled: field.enabled,
        obscureText: field.obscureText,
        enableSuggestions: field.enableSuggestions,
        enableIMEPersonalizedLearning: field.enableIMEPersonalizedLearning,
        autofillHints: field.autofillHints,
        textAlign: field.textAlign,
        textCapitalization: field.textCapitalization,
        cursorColor: field.cursorColor,
        scrollPhysics: field.scrollPhysics,
        keyboardType: field.keyboardType,
        textInputAction: field.textInputAction,
        inputFormatters: field.inputFormatters,
        maxLines: field.maxLines,
        minLines: field.minLines,
        maxLength: field.maxLength,
        autofocus: field.autofocus,
        onChanged: widget.onChanged ?? field.onChanged,
        onSubmitted: field.onSubmitted,
        scrollPadding: field.scrollPadding,
        autocorrect: field.autocorrect,
        decoration: null,
        padding: EdgeInsets.zero,
        style: style,
      ),
    );
  }

  @override
  void dispose() {
    _localController.dispose();
    _focus.dispose();
    super.dispose();
  }
}

class _ExpressiveTextFormFieldState extends FormFieldState<String> {
  late TextEditingController _controller;
  late final bool _syncIosController;

  @override
  _ExpressiveTextFormField get widget =>
      super.widget as _ExpressiveTextFormField;

  @override
  void initState() {
    super.initState();
    _controller = widget.field.controller ?? TextEditingController(text: value);
    _syncIosController = usesIosVisualStyle;
    if (_syncIosController) _controller.addListener(_controllerChanged);
  }

  void _controllerChanged() {
    if (_controller.text != value) didChange(_controller.text);
  }

  @override
  void didUpdateWidget(_ExpressiveTextFormField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.field.controller != widget.field.controller) {
      final previous = _controller;
      if (_syncIosController) previous.removeListener(_controllerChanged);
      _controller =
          widget.field.controller ??
          TextEditingController.fromValue(previous.value);
      if (oldWidget.field.controller == null) previous.dispose();
      if (_syncIosController) _controller.addListener(_controllerChanged);
      setValue(_controller.text);
    }
  }

  @override
  void reset() {
    if (_syncIosController) _controller.removeListener(_controllerChanged);
    _controller.text = widget.initialValue ?? '';
    super.reset();
    if (_syncIosController) _controller.addListener(_controllerChanged);
  }

  @override
  void dispose() {
    if (_syncIosController) _controller.removeListener(_controllerChanged);
    if (widget.field.controller == null) _controller.dispose();
    super.dispose();
  }
}
