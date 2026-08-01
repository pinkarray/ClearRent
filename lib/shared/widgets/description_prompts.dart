import 'package:flutter/material.dart';
import '../../core/constants/colors.dart';
import '../../core/constants/text_styles.dart';

/// Tappable prompts under a property description field.
///
/// The auto-generated description can only restate what the structured fields
/// already show (bedrooms, amenities). What actually helps a tenant decide is
/// local knowledge no field captures — the landmark to turn at, whether the road
/// floods, borehole or public water. These prompts insert a starter line and let
/// the landlord finish it in their own words, which reads more honestly than
/// generated copy.
///
/// A prompt hides once its starter line is present, so the list shrinks as the
/// description fills out. That check reads the text itself rather than tracking
/// taps, so it stays correct across a draft resume.
class DescriptionPrompts extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;

  /// Called after a prompt is inserted — the caller marks the description as
  /// edited, saves the draft, flags unsaved changes, etc.
  final VoidCallback? onInserted;

  const DescriptionPrompts({
    super.key,
    required this.controller,
    required this.focusNode,
    this.onInserted,
  });

  @override
  State<DescriptionPrompts> createState() => _DescriptionPromptsState();
}

class _DescriptionPromptsState extends State<DescriptionPrompts> {
  /// label → starter line inserted into the description.
  static const _prompts = <String, String>{
    'Nearest landmark': 'Closest landmark: ',
    'Road access': 'Getting here: ',
    // No water/power prompt: "24/7 Power Supply", "Running Water" and
    // "Prepaid Meter" are already amenity checkboxes. Prompts are for what the
    // structured fields can't capture, not a second place to say the same thing.
    "What's nearby": 'Nearby: ',
    'Who it suits': 'Best suited to: ',
    // Framed around the property, not the person. A tenant who learns on
    // arrival that it's a 3rd-floor walk-up has wasted an inspection fee, so
    // saying so upfront saves everyone. Keep the starter about the place —
    // "Not ideal for" invites a description of the home, where a prompt like
    // "who I don't want" would invite the tenant's tribe or religion.
    'Not ideal for': 'Not ideal for: ',
  };

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    if (mounted) setState(() {});
  }

  void _insert(String starter) {
    final current = widget.controller.text;
    final needsBreak = current.trim().isNotEmpty;
    final text = needsBreak ? '${current.trimRight()}\n\n$starter' : starter;

    widget.controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    widget.focusNode.requestFocus();
    widget.onInserted?.call();

    // Focusing opens the keyboard, which can push the description field off
    // screen — the line gets inserted but the landlord never sees it happen and
    // assumes the chip did nothing. Bring the field back into view.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final fieldContext = widget.focusNode.context;
      if (fieldContext == null || !mounted) return;
      Scrollable.ensureVisible(
        fieldContext,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
        alignment: 0.15,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = widget.controller.text;
    final remaining = _prompts.entries
        .where((e) => !text.contains(e.value.trim()))
        .toList();

    if (remaining.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Name the destination. These sit directly under a text field and
          // look like the amenity chips above them, so "tap to add one" reads
          // as picking a tag rather than writing into the description.
          Row(
            children: [
              Icon(Icons.arrow_upward, size: 11, color: AppColors.textSecondary),
              const SizedBox(width: 3),
              Text(
                'Tap to add a line to your description',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Tenants always ask about these — you finish the sentence',
            style: AppTextStyles.caption.copyWith(
              color: AppColors.textHint,
              fontSize: 10,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: remaining.map((entry) {
              return GestureDetector(
                onTap: () => _insert(entry.value),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withAlpha(15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppColors.primary.withAlpha(60)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add, size: 13, color: AppColors.primary),
                      const SizedBox(width: 4),
                      Text(
                        entry.key,
                        style: AppTextStyles.caption.copyWith(
                          color: AppColors.primary,
                          fontWeight: FontWeight.w600,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
